// kippbus tray: owns org.kde.StatusNotifierWatcher and prints what registers
// as tray/<item>, with its menu as tray/<item>/menu/<entry>. A tray
// application looks for the name once, at its own startup: if nobody owns it,
// no icon ever registers.
//
//   tray/<item>             state=registered icon= icon_path= pixmap= title= status= is_menu=0|1
//   tray/<item>/menu/<id>   parent= position= label= enabled=0|1 kind=standard|separator
//                           toggle=none|check|radio state=0|1 submenu=0|1
//
// pixmap= is a TGA file under $XDG_RUNTIME_DIR/kippbus/tray, for items that
// send pixels instead of an icon name. Each new picture is a new file.
//
// stdin takes kipp request lines:
//
//   publish tray/request action=activate|secondary|menu item=<bus name>/<path> x= y=
//   publish tray/request action=scroll item= delta= dir=vertical|horizontal
//   publish tray/request action=open|click item= entry=<id>
//
// open is sent before a menu or submenu shows, since some applications fill
// it only then; click runs an entry.
package kippbus

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

TRAY_NAME      :: "org.kde.StatusNotifierWatcher"
TRAY_PATH      :: "/StatusNotifierWatcher"
TRAY_INTERFACE :: "org.kde.StatusNotifierWatcher"
ITEM_INTERFACE :: "org.kde.StatusNotifierItem"
MENU_INTERFACE :: "com.canonical.dbusmenu"
PIXMAP_SIDE    :: 1024   // larger pictures are refused

MESSAGE_METHOD_RETURN :: 2
MESSAGE_METHOD_ERROR  :: 3
MESSAGE_SIGNAL        :: 4

Item :: struct {
	key:         string,           // "<bus name>/<path>", as the protocol gives them
	owner:       string,           // the unique name its signals come from
	destination: string,           // the key up to the path
	path:        string,           // the key from the first slash
	menu:        string,           // its dbusmenu object path; empty when it has none
	pixmap:      string,           // the file last written for it; empty when none
	entries:     map[i32]string,   // menu entry -> the retain line last printed for it
}

Properties :: struct {
	icon, icon_path, title, status: string,
	is_menu:                        bool,
}

Reply_Kind :: enum {
	Properties,
	Layout,
}

Pending :: struct {
	key:  string,
	kind: Reply_Kind,
}

@(private = "file") items: [dynamic]^Item
@(private = "file") hosts: [dynamic]string     // bus names, so one that exits stops counting
@(private = "file") pending: map[u64]Pending   // reply cookie -> what was asked
@(private = "file") pixmap_count: int          // so each picture gets a new file name

// ------------------------------------------------------------- the facts

@(private = "file")
print_item :: proc(item: ^Item, properties: Properties) {
	builder := strings.builder_make(context.temp_allocator)
	begin_retain(&builder, fmt.tprintf("tray/%s", item.key))
	add_field(&builder, "state", "registered")
	add_field(&builder, "icon", properties.icon)
	add_field(&builder, "icon_path", properties.icon_path)
	add_field(&builder, "pixmap", item.pixmap)
	add_field(&builder, "title", properties.title)
	add_field(&builder, "status", properties.status)
	add_field(&builder, "is_menu", properties.is_menu ? "1" : "0")
	write_line(strings.to_string(builder))
}

@(private = "file")
print_delete :: proc(topic: string) {
	builder := strings.builder_make(context.temp_allocator)
	begin_delete(&builder, topic)
	write_line(strings.to_string(builder))
}

@(private = "file")
entry_topic :: proc(item: ^Item, id: i32) -> string {
	return fmt.tprintf("tray/%s/menu/%d", item.key, id)
}

@(private = "file")
find_item :: proc(key: string) -> ^Item {
	for item in items do if item.key == key do return item
	return nil
}

@(private = "file")
item_free :: proc(item: ^Item) {
	if item.pixmap != "" do _ = os.remove(item.pixmap)
	for _, line in item.entries do delete(line)
	delete(item.entries)
	delete(item.key); delete(item.owner); delete(item.menu); delete(item.pixmap)
	free(item)
}

// ------------------------------------------------------ asking the item

@(private = "file")
ask_properties :: proc(item: ^Item) {
	cookie, sent := call_method_with_reply(item.destination, item.path, "org.freedesktop.DBus.Properties",
	                                       "GetAll", "s", {ITEM_INTERFACE})
	if sent do pending[cookie] = {strings.clone(item.key), .Properties}
}

// The whole tree, every property.
@(private = "file")
ask_layout :: proc(item: ^Item) {
	if item.menu == "" do return
	message: ^Bus_Message
	if bus_message_new_method_call(connection, &message, cstr(item.destination), cstr(item.menu),
	                               MENU_INTERFACE, "GetLayout") < 0 {
		return
	}
	root, depth := i32(0), i32(-1)
	bus_message_append_basic(message, 'i', &root)
	bus_message_append_basic(message, 'i', &depth)
	bus_message_open_container(message, 'a', "s")
	bus_message_close_container(message)
	cookie, sent := send_with_reply(message)
	if sent do pending[cookie] = {strings.clone(item.key), .Layout}
}

// ---------------------------------------------------------- the replies

@(private = "file")
read_string :: proc(message: ^Bus_Message, type: u8) -> string {
	text: cstring
	if bus_message_read_basic(message, type, &text) < 0 do return ""
	return strings.clone(text_of(text), context.temp_allocator)
}

@(private = "file")
read_bool :: proc(message: ^Bus_Message) -> bool {
	value: b32
	bus_message_read_basic(message, 'b', &value)
	return bool(value)
}

// a{sv} of the item's interface; the pixmap is written to its file here.
@(private = "file")
take_properties :: proc(item: ^Item, message: ^Bus_Message) {
	properties: Properties
	menu := ""
	if bus_message_enter_container(message, 'a', "{sv}") < 0 do return
	for bus_message_enter_container(message, 'e', "sv") > 0 {
		key: cstring
		if bus_message_read_basic(message, 's', &key) < 0 do return
		if bus_message_enter_container(message, 'v', nil) <= 0 do return
		type: u8
		contents: cstring
		bus_message_peek_type(message, &type, &contents)
		switch name := string(key); {
		case name == "IconName" && type == 's':      properties.icon = read_string(message, 's')
		case name == "IconThemePath" && type == 's': properties.icon_path = read_string(message, 's')
		case name == "Title" && type == 's':         properties.title = read_string(message, 's')
		case name == "Status" && type == 's':        properties.status = read_string(message, 's')
		case name == "ItemIsMenu" && type == 'b':    properties.is_menu = read_bool(message)
		case name == "Menu" && type == 'o':          menu = read_string(message, 'o')
		case name == "IconPixmap" && type == 'a':    take_pixmap(item, message)
		case:                                        bus_message_skip(message, nil)
		}
		bus_message_exit_container(message)
		bus_message_exit_container(message)
	}
	bus_message_exit_container(message)

	print_item(item, properties)
	if menu != item.menu {
		delete(item.menu)
		item.menu = strings.clone(menu)
		ask_layout(item)
	}
}

// a(iiay): the largest picture, as a TGA file. The item's ARGB in network
// order becomes TGA's BGRA, rows top first.
@(private = "file")
take_pixmap :: proc(item: ^Item, message: ^Bus_Message) {
	width, height: i32
	pixels: []byte
	if bus_message_enter_container(message, 'a', "(iiay)") < 0 do return
	for bus_message_enter_container(message, 'r', "iiay") > 0 {
		this_width, this_height: i32
		data: rawptr
		size: c.size_t
		bus_message_read_basic(message, 'i', &this_width)
		bus_message_read_basic(message, 'i', &this_height)
		bus_message_read_array(message, 'y', &data, &size)
		bus_message_exit_container(message)
		valid := this_width > 0 && this_height > 0 && this_width <= PIXMAP_SIDE && this_height <= PIXMAP_SIDE &&
		         int(size) == int(this_width) * int(this_height) * 4
		if valid && this_width * this_height > width * height {
			width, height = this_width, this_height
			pixels = ([^]byte)(data)[:size]
		}
	}
	bus_message_exit_container(message)
	if pixels == nil do return

	folder := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if folder == "" do return
	folder = fmt.tprintf("%s/kippbus/tray", folder)
	_ = os.make_directory_all(folder)

	file := make([]byte, 18 + len(pixels), context.temp_allocator)
	file[2] = 2                                      // uncompressed true color
	file[12], file[13] = u8(width), u8(width >> 8)
	file[14], file[15] = u8(height), u8(height >> 8)
	file[16] = 32                                    // bits per pixel
	file[17] = 0x28                                  // 8 alpha bits, top row first
	for index := 0; index < len(pixels); index += 4 {
		file[18 + index + 0] = pixels[index + 3]
		file[18 + index + 1] = pixels[index + 2]
		file[18 + index + 2] = pixels[index + 1]
		file[18 + index + 3] = pixels[index + 0]
	}
	name, _ := strings.replace_all(item.key, "/", "_", context.temp_allocator)
	pixmap_count += 1
	path := fmt.aprintf("%s/%s-%d.tga", folder, name, pixmap_count)
	if os.write_entire_file(path, file) != nil {
		delete(path)
		return
	}
	if item.pixmap != "" do _ = os.remove(item.pixmap)
	delete(item.pixmap)
	item.pixmap = path
}

// (u (ia{sv}av)): every shown entry under the root, compared with what was
// printed, so only changed entries go out and gone ones are deleted.
@(private = "file")
take_layout :: proc(item: ^Item, message: ^Bus_Message) {
	revision: u32
	if bus_message_read_basic(message, 'u', &revision) < 0 do return
	entries := make(map[i32]string)
	read_entry(item, message, 0, 0, &entries)

	ids, _ := slice.map_keys(entries, context.temp_allocator)
	slice.sort(ids)
	for id in ids {
		if item.entries[id] != entries[id] do write_line(entries[id])
	}
	for id, line in item.entries {
		if id not_in entries do print_delete(entry_topic(item, id))
		delete(line)
	}
	delete(item.entries)
	item.entries = entries
}

// One (ia{sv}av) and its children. The root, id 0, is not an entry.
@(private = "file")
read_entry :: proc(item: ^Item, message: ^Bus_Message, parent: i32, position: int, entries: ^map[i32]string) {
	if bus_message_enter_container(message, 'r', "ia{sv}av") <= 0 do return
	defer bus_message_exit_container(message)

	id, state: i32
	bus_message_read_basic(message, 'i', &id)
	label, kind, toggle := "", "standard", "none"
	enabled, visible, submenu := true, true, false
	if bus_message_enter_container(message, 'a', "{sv}") < 0 do return
	for bus_message_enter_container(message, 'e', "sv") > 0 {
		key: cstring
		bus_message_read_basic(message, 's', &key)
		if bus_message_enter_container(message, 'v', nil) <= 0 do return
		type: u8
		contents: cstring
		bus_message_peek_type(message, &type, &contents)
		switch name := string(key); {
		case name == "label" && type == 's':            label = mnemonic_removed(read_string(message, 's'))
		case name == "enabled" && type == 'b':          enabled = read_bool(message)
		case name == "visible" && type == 'b':          visible = read_bool(message)
		case name == "type" && type == 's':             kind = read_string(message, 's') == "separator" ? "separator" : "standard"
		case name == "toggle-state" && type == 'i':     bus_message_read_basic(message, 'i', &state)
		case name == "children-display" && type == 's': submenu = read_string(message, 's') == "submenu"
		case name == "toggle-type" && type == 's':
			switch read_string(message, 's') {
			case "checkmark": toggle = "check"
			case "radio":     toggle = "radio"
			}
		case:
			bus_message_skip(message, nil)
		}
		bus_message_exit_container(message)
		bus_message_exit_container(message)
	}
	bus_message_exit_container(message)

	if !visible {
		bus_message_skip(message, "av")
		return
	}
	if id != 0 {
		builder := strings.builder_make()
		begin_retain(&builder, entry_topic(item, id))
		add_field(&builder, "parent", fmt.tprint(parent))
		add_field(&builder, "position", fmt.tprint(position))
		add_field(&builder, "label", label)
		add_field(&builder, "enabled", enabled ? "1" : "0")
		add_field(&builder, "kind", kind)
		add_field(&builder, "toggle", toggle)
		add_field(&builder, "state", state == 1 ? "1" : "0")
		add_field(&builder, "submenu", submenu ? "1" : "0")
		entries[id] = strings.to_string(builder)
	}

	if bus_message_enter_container(message, 'a', "v") < 0 do return
	for index := 0; bus_message_enter_container(message, 'v', "(ia{sv}av)") > 0; index += 1 {
		read_entry(item, message, id, index, entries)
		bus_message_exit_container(message)
	}
	bus_message_exit_container(message)
}

// "_Open" is "Open", and "__" is a plain underscore.
@(private = "file")
mnemonic_removed :: proc(label: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(label); index += 1 {
		if label[index] == '_' && index + 1 < len(label) do index += 1
		strings.write_byte(&builder, label[index])
	}
	return strings.to_string(builder)
}

// ------------------------------------------------------------- callbacks

@(private = "file")
on_register_item :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	argument: cstring
	if bus_message_read_basic(message, 's', &argument) < 0 do return -22

	// Either a bus name or an object path on the sender's own connection.
	service := string(argument)
	sender := text_of(bus_message_get_sender(message))
	key := strings.has_prefix(service, "/") \
		? fmt.aprintf("%s%s", sender, service) \
		: fmt.aprintf("%s/StatusNotifierItem", service)

	// Replied first: an application that waits for the reply could not
	// answer the questions that follow.
	reply_empty(message)
	if find_item(key) != nil {
		delete(key)
		return 1
	}
	slash := strings.index_byte(key, '/')
	item := new(Item)
	item^ = {key = key, owner = strings.clone(sender), destination = key[:slash], path = key[slash:]}
	append(&items, item)
	print_item(item, {})
	properties_changed()
	emit_signal("StatusNotifierItemRegistered", key)
	ask_properties(item)
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
	for item in items do bus_message_append_basic(reply, 's', rawptr(cstr(item.key)))
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

@(private = "file")
take_message :: proc(message: ^Bus_Message) {
	type: u8
	bus_message_get_type(message, &type)
	switch type {
	case MESSAGE_METHOD_RETURN, MESSAGE_METHOD_ERROR: take_reply(message, type)
	case MESSAGE_SIGNAL:                              take_signal(message)
	}
}

@(private = "file")
take_reply :: proc(message: ^Bus_Message, type: u8) {
	cookie: u64
	if bus_message_get_reply_cookie(message, &cookie) < 0 do return
	asked, found := pending[cookie]
	if !found do return
	delete_key(&pending, cookie)
	defer delete(asked.key)
	item := find_item(asked.key)
	if item == nil || type == MESSAGE_METHOD_ERROR do return
	switch asked.kind {
	case .Properties: take_properties(item, message)
	case .Layout:     take_layout(item, message)
	}
}

// An item's own signals all mean a property changed; a menu's mean its layout did.
@(private = "file")
take_signal :: proc(message: ^Bus_Message) {
	interface := text_of(bus_message_get_interface(message))
	if interface == "org.freedesktop.DBus" {
		notice_departure(message)
		return
	}
	sender := text_of(bus_message_get_sender(message))
	path := text_of(bus_message_get_path(message))
	for item in items {
		if item.owner != sender do continue
		if interface == ITEM_INTERFACE && item.path == path do ask_properties(item)
		if interface == MENU_INTERFACE && item.menu == path do ask_layout(item)
	}
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
		item := items[index]
		if !strings.has_prefix(item.key, gone) do continue
		for id in item.entries do print_delete(entry_topic(item, id))
		print_delete(fmt.tprintf("tray/%s", item.key))
		emit_signal("StatusNotifierItemUnregistered", item.key)
		item_free(item)
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

	item := find_item(payload["item"])
	if item == nil {
		refuse("tray", "item= names no registered item", line)
		return
	}
	position := []string{payload["x"] or_else "0", payload["y"] or_else "0"}

	sent: bool
	switch action := payload["action"]; action {
	case "activate":
		sent = call_method(item.destination, item.path, ITEM_INTERFACE, "Activate", "ii", position)
	case "secondary":
		sent = call_method(item.destination, item.path, ITEM_INTERFACE, "SecondaryActivate", "ii", position)
	case "menu":
		sent = call_method(item.destination, item.path, ITEM_INTERFACE, "ContextMenu", "ii", position)
	case "scroll":
		direction := payload["dir"] or_else "vertical"
		if direction != "vertical" && direction != "horizontal" {
			refuse("tray", "dir= is vertical or horizontal", line)
			return
		}
		sent = call_method(item.destination, item.path, ITEM_INTERFACE, "Scroll", "is",
		                   {payload["delta"] or_else "0", direction})
	case "open", "click":
		entry, valid := strconv.parse_i64(payload["entry"])
		if !valid || item.menu == "" {
			refuse("tray", "open and click need entry= and an item with a menu", line)
			return
		}
		if action == "click" {
			sent = send_click(item, i32(entry))
			break
		}
		// The layout is asked after, so it holds whatever AboutToShow filled in.
		sent = call_method(item.destination, item.menu, MENU_INTERFACE, "AboutToShow", "i", {payload["entry"]})
		ask_layout(item)
	case:
		refuse("tray", "unknown action", line)
		return
	}
	if !sent do refuse("tray", "the bus would not take it", line)
}

// Event(i id, s "clicked", v data, u timestamp), which new_call cannot build: v needs a shape.
@(private = "file")
send_click :: proc(item: ^Item, entry: i32) -> bool {
	message: ^Bus_Message
	if bus_message_new_method_call(connection, &message, cstr(item.destination), cstr(item.menu),
	                               MENU_INTERFACE, "Event") < 0 {
		return false
	}
	defer bus_message_unref(message)
	entry, data, timestamp := entry, i32(0), u32(0)
	bus_message_append_basic(message, 'i', &entry)
	bus_message_append_basic(message, 's', rawptr(cstr("clicked")))
	bus_message_open_container(message, 'v', "i")
	bus_message_append_basic(message, 'i', &data)
	bus_message_close_container(message)
	bus_message_append_basic(message, 'u', &timestamp)
	bus_message_set_expect_reply(message, 0)
	return bus_send(connection, message, nil) >= 0
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
	bus_add_match(connection, nil, "type='signal',interface='" + ITEM_INTERFACE + "'", nil, nil)
	bus_add_match(connection, nil, "type='signal',interface='" + MENU_INTERFACE + "'", nil, nil)

	if bus_request_name(connection, cstr(name), 0) < 0 {
		fmt.eprintfln(
`kippbus: %s is already owned by another program, so the tray will stay
         empty. Stop whatever holds it, then restart kippsrv and any
         application with a tray icon. [E-name] See DIAGNOSTICS.md.`, name)
		return {}, false
	}
	return {on_message = take_message, on_line = take_request}, true
}
