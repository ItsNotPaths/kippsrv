// kippbus tray: owns org.kde.StatusNotifierWatcher and prints what registers
// as tray/<item>. A tray application looks for the name once, at its own
// startup: if nobody owns it, no icon ever registers.
//
// stdin takes kipp request lines:
//
//   publish tray/request action=activate|secondary|menu item=<bus name>/<path> x= y=
//   publish tray/request action=scroll item= delta= dir=vertical|horizontal
package kippbus

import "core:c"
import "core:fmt"
import "core:strings"

TRAY_NAME      :: "org.kde.StatusNotifierWatcher"
TRAY_PATH      :: "/StatusNotifierWatcher"
TRAY_INTERFACE :: "org.kde.StatusNotifierWatcher"
ITEM_INTERFACE :: "org.kde.StatusNotifierItem"

@(private = "file") items: [dynamic]string   // "<bus name>/<path>", as the protocol gives them
@(private = "file") hosts: [dynamic]string   // bus names, so one that exits stops counting

@(private = "file")
print_item :: proc(item: string) {
	builder := strings.builder_make(context.temp_allocator)
	begin_retain(&builder, fmt.tprintf("tray/%s", item))
	add_field(&builder, "state", "registered")
	write_line(strings.to_string(builder))
}

@(private = "file")
print_gone :: proc(item: string) {
	builder := strings.builder_make(context.temp_allocator)
	begin_delete(&builder, fmt.tprintf("tray/%s", item))
	write_line(strings.to_string(builder))
}

// ------------------------------------------------------------- callbacks

@(private = "file")
on_register_item :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	argument: cstring
	if bus_message_read_basic(message, 's', &argument) < 0 do return -22

	// Either a bus name or an object path on the sender's own connection.
	service := string(argument)
	item := strings.has_prefix(service, "/") \
		? fmt.aprintf("%s%s", text_of(bus_message_get_sender(message)), service) \
		: fmt.aprintf("%s/StatusNotifierItem", service)

	if listed(items[:], item) {
		delete(item)
	} else {
		append(&items, item)
		print_item(item)
		properties_changed()
		emit_signal("StatusNotifierItemRegistered", item)
	}
	reply_empty(message)
	return 1
}

@(private = "file")
on_register_host :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	host := text_of(bus_message_get_sender(message))
	if !listed(hosts[:], host) {
		append(&hosts, strings.clone(host))
		properties_changed()
		emit_signal("StatusNotifierHostRegistered", "")
	}
	reply_empty(message)
	return 1
}

@(private = "file")
get_items :: proc "c" (bus: ^Bus, path, interface, property: cstring,
                       reply: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	if bus_message_open_container(reply, 'a', "s") < 0 do return -22
	for item in items do bus_message_append_basic(reply, 's', rawptr(cstr(item)))
	bus_message_close_container(reply)
	return 1
}

@(private = "file")
get_host_registered :: proc "c" (bus: ^Bus, path, interface, property: cstring,
                                 reply: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	value := b32(len(hosts) > 0)
	bus_message_append_basic(reply, 'b', &value)
	return 1
}

@(private = "file")
get_protocol_version :: proc "c" (bus: ^Bus, path, interface, property: cstring,
                                  reply: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	value := i32(0)
	bus_message_append_basic(reply, 'i', &value)
	return 1
}

@(private = "file")
listed :: proc(list: []string, wanted: string) -> bool {
	for entry in list do if entry == wanted do return true
	return false
}

@(private = "file")
emit_signal :: proc(member: string, argument: string) {
	message: ^Bus_Message
	if bus_message_new_signal(connection, &message, TRAY_PATH, TRAY_INTERFACE, cstr(member)) < 0 do return
	defer bus_message_unref(message)
	if argument != "" do bus_message_append_basic(message, 's', rawptr(cstr(argument)))
	bus_send(connection, message, nil)
}

// A client that waits for the signal rather than polling depends on it.
@(private = "file")
properties_changed :: proc() {
	names := []cstring{"RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", nil}
	bus_emit_properties_changed_strv(connection, TRAY_PATH, TRAY_INTERFACE, raw_data(names))
}

// An application that exits does not unregister, so NameOwnerChanged is the
// only notice it left.
@(private = "file")
notice_departure :: proc(message: ^Bus_Message) {
	if text_of(bus_message_get_member(message)) != "NameOwnerChanged" do return

	name, old_owner, new_owner: cstring
	if bus_message_read_basic(message, 's', &name) < 0 do return
	if bus_message_read_basic(message, 's', &old_owner) < 0 do return
	if bus_message_read_basic(message, 's', &new_owner) < 0 do return
	if text_of(new_owner) != "" do return   // it moved, not left

	// The separator matters: ":1.4" is a prefix of ":1.42/...".
	gone := fmt.tprintf("%s/", name)
	for index := 0; index < len(items); index += 1 {
		if !strings.has_prefix(items[index], gone) do continue
		print_gone(items[index])
		emit_signal("StatusNotifierItemUnregistered", items[index])
		delete(items[index])
		ordered_remove(&items, index)
		index -= 1
		properties_changed()
	}
	for index := 0; index < len(hosts); index += 1 {
		if hosts[index] != string(name) do continue
		delete(hosts[index])
		ordered_remove(&hosts, index)
		index -= 1
		properties_changed()
	}
}

// ------------------------------------------------------------- requests

@(private = "file")
take_request :: proc(line: string) {
	payload := payload_of(line)

	item := payload["item"]
	slash := strings.index_byte(item, '/')
	if slash <= 0 {
		refuse("tray", "item= is <bus name>/<object path>", line)
		return
	}
	destination, path := item[:slash], item[slash:]
	position := []string{payload["x"] or_else "0", payload["y"] or_else "0"}

	sent: bool
	switch payload["action"] {
	case "activate":
		sent = call_method(destination, path, ITEM_INTERFACE, "Activate", "ii", position)
	case "secondary":
		sent = call_method(destination, path, ITEM_INTERFACE, "SecondaryActivate", "ii", position)
	case "menu":
		sent = call_method(destination, path, ITEM_INTERFACE, "ContextMenu", "ii", position)
	case "scroll":
		direction := payload["dir"] or_else "vertical"
		if direction != "vertical" && direction != "horizontal" {
			refuse("tray", "dir= is vertical or horizontal", line)
			return
		}
		sent = call_method(destination, path, ITEM_INTERFACE, "Scroll", "is",
		                   {payload["delta"] or_else "0", direction})
	case:
		refuse("tray", "unknown action", line)
		return
	}
	if !sent do refuse("tray", "the bus would not take it", line)
}

// ----------------------------------------------------------------- start

tray_start :: proc(arguments: []string) -> (Handlers, bool) {
	name := len(arguments) > 0 ? arguments[0] : TRAY_NAME
	if !open_bus(false) do return {}, false

	@(static) vtable: [10]Vtable
	vtable = {
		vtable_start(),
		vtable_method("RegisterStatusNotifierItem", "s", "", on_register_item),
		vtable_method("RegisterStatusNotifierHost", "s", "", on_register_host),
		vtable_property("RegisteredStatusNotifierItems", "as", get_items, PROPERTY_EMITS_CHANGE),
		vtable_property("IsStatusNotifierHostRegistered", "b", get_host_registered, PROPERTY_EMITS_CHANGE),
		vtable_property("ProtocolVersion", "i", get_protocol_version, 0),
		vtable_signal("StatusNotifierItemRegistered", "s"),
		vtable_signal("StatusNotifierItemUnregistered", "s"),
		vtable_signal("StatusNotifierHostRegistered", ""),
		vtable_end(),
	}
	if result := bus_add_object_vtable(connection, nil, TRAY_PATH, TRAY_INTERFACE,
	                                   &vtable[0], nil); result < 0 {
		fmt.eprintfln(
`kippbus: could not export the watcher interface (%d), so the tray will stay
         empty. [E-name] See DIAGNOSTICS.md.`, result)
		return {}, false
	}

	bus_add_match(connection, nil,
	              "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
	              nil, nil)

	if bus_request_name(connection, cstr(name), 0) < 0 {
		fmt.eprintfln(
`kippbus: %s is already owned by another program, so the tray will stay
         empty. Stop whatever holds it, then restart kippsrv and any
         application with a tray icon. [E-name] See DIAGNOSTICS.md.`, name)
		return {}, false
	}
	return {on_message = notice_departure, on_line = take_request}, true
}
