// kippbus notify: owns org.freedesktop.Notifications and prints each one as
// notif/<id>. `notify-send` calls whoever holds the name, so holding it is the
// whole of being a daemon.
//
//   notif/<id>  app= summary= body= icon= urgency=low|normal|critical read=0|1
//               action= exec=
//
// stdin takes kipp request lines:
//
//   publish notif/request action=close id=<id>
//   publish notif/request action=read          everything live becomes read=1
package kippbus

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"

NOTIFY_NAME      :: "org.freedesktop.Notifications"
NOTIFY_PATH      :: "/org/freedesktop/Notifications"
NOTIFY_INTERFACE :: "org.freedesktop.Notifications"

// Reasons, from the spec's NotificationClosed signal.
CLOSED_DISMISSED :: u32(2)
CLOSED_REQUESTED :: u32(3)

@(private = "file", rodata)
URGENCY_WORD := [3]string{"low", "normal", "critical"}

Note :: struct {
	identifier: u32,
	app:        string,
	icon:       string,
	summary:    string,
	body:       string,
	urgency:    u8,       // the spec's numbering, an index into URGENCY_WORD
	action:     string,   // the first action's key
	exec:       string,   // a command the sender attached, which is what runs
	read:       bool,
}

@(private = "file") notes: [dynamic]Note
@(private = "file") next_identifier: u32 = 1   // 0 means "no replacement" in the protocol

@(private = "file")
note_free :: proc(note: Note) {
	delete(note.app); delete(note.icon); delete(note.summary); delete(note.body)
	delete(note.action); delete(note.exec)
}

@(private = "file")
find :: proc(identifier: u32) -> int {
	for note, index in notes do if note.identifier == identifier do return index
	return -1
}

@(private = "file")
print_note :: proc(note: Note) {
	builder := strings.builder_make(context.temp_allocator)
	begin_retain(&builder, fmt.tprintf("notif/%d", note.identifier))
	add_field(&builder, "app", note.app)
	add_field(&builder, "summary", note.summary)
	add_field(&builder, "body", note.body)
	add_field(&builder, "icon", note.icon)
	add_field(&builder, "action", note.action)
	add_field(&builder, "exec", note.exec)
	add_field(&builder, "urgency", URGENCY_WORD[min(note.urgency, 2)])
	add_field(&builder, "read", note.read ? "1" : "0")
	write_line(strings.to_string(builder))
}

// Gone, not stale: the delete tells the store so.
@(private = "file")
close_note :: proc(identifier: u32, reason: u32) -> bool {
	index := find(identifier)
	if index < 0 do return false

	note_free(notes[index])
	ordered_remove(&notes, index)
	write_line(fmt.tprintf("delete\tnotif/%d", identifier))
	emit_closed(identifier, reason)
	return true
}

@(private = "file")
emit_closed :: proc(identifier: u32, reason: u32) {
	message: ^Bus_Message
	if bus_message_new_signal(connection, &message, NOTIFY_PATH, NOTIFY_INTERFACE,
	                          "NotificationClosed") < 0 {
		return
	}
	defer bus_message_unref(message)

	closed, why := identifier, reason
	bus_message_append_basic(message, 'u', &closed)
	bus_message_append_basic(message, 'u', &why)
	bus_send(connection, message, nil)
}

// ------------------------------------------------------------- the hints
//
// a{sv}. Three keys change what a note says; the rest are skipped unread.
//
// x-kipp-exec is ours. The spec has the sender act on ActionInvoked, which
// needs it still running, and notify-send exits long before anyone looks. A
// command carried on the note outlives the process that sent it.

@(private = "file")
read_hints :: proc(message: ^Bus_Message, note: ^Note) {
	if bus_message_enter_container(message, 'a', "{sv}") < 0 do return
	defer bus_message_exit_container(message)

	for bus_message_enter_container(message, 'e', "sv") > 0 {
		defer bus_message_exit_container(message)

		key: cstring
		if bus_message_read_basic(message, 's', &key) < 0 do return
		if bus_message_enter_container(message, 'v', nil) <= 0 do continue
		defer bus_message_exit_container(message)

		type: u8
		contents: cstring
		if bus_message_peek_type(message, &type, &contents) <= 0 do continue

		name := string(key)
		text: cstring
		switch {
		case name == "urgency" && type == 'y':
			bus_message_read_basic(message, 'y', &note.urgency)
		case name == "x-kipp-exec" && type == 's':
			if bus_message_read_basic(message, 's', &text) >= 0 do note.exec = strings.clone(string(text))
		case (name == "image-path" || name == "image_path") && type == 's' && note.icon == "":
			if bus_message_read_basic(message, 's', &text) >= 0 do note.icon = strings.clone(string(text))
		}
	}
}

// as, paired key and label. Return runs one thing, so only the first key is kept.
@(private = "file")
read_first_action :: proc(message: ^Bus_Message) -> string {
	if bus_message_enter_container(message, 'a', "s") < 0 do return ""
	defer bus_message_exit_container(message)

	first: cstring
	if bus_message_read_basic(message, 's', &first) <= 0 do return ""
	for {
		rest: cstring
		if bus_message_read_basic(message, 's', &rest) <= 0 do break
	}
	return strings.clone(string(first))
}

// ------------------------------------------------------------- callbacks

@(private = "file")
on_notify :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	app, icon, summary, body: cstring
	replaces: u32
	if bus_message_read_basic(message, 's', &app) < 0 do return -22
	if bus_message_read_basic(message, 'u', &replaces) < 0 do return -22
	if bus_message_read_basic(message, 's', &icon) < 0 do return -22
	if bus_message_read_basic(message, 's', &summary) < 0 do return -22
	if bus_message_read_basic(message, 's', &body) < 0 do return -22

	note := Note{
		app     = strings.clone(text_of(app)),
		icon    = strings.clone(text_of(icon)),
		summary = strings.clone(text_of(summary)),
		body    = strings.clone(text_of(body)),
		urgency = 1,
	}
	note.action = read_first_action(message)
	read_hints(message, &note)

	// A replacement keeps its place, so a progress note does not walk down
	// the panel as it updates.
	if index := find(replaces); replaces != 0 && index >= 0 {
		note.identifier = replaces
		note.read = notes[index].read
		note_free(notes[index])
		notes[index] = note
	} else {
		note.identifier = next_identifier
		next_identifier += 1
		append(&notes, note)
	}
	print_note(note)

	reply: ^Bus_Message
	if bus_message_new_method_return(message, &reply) < 0 do return 1
	defer bus_message_unref(reply)
	bus_message_append_basic(reply, 'u', &note.identifier)
	bus_send(connection, reply, nil)
	return 1
}

@(private = "file")
on_close :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context

	identifier: u32
	if bus_message_read_basic(message, 'u', &identifier) < 0 do return -22
	close_note(identifier, CLOSED_REQUESTED)
	reply_empty(message)
	return 1
}

// What we do and nothing more. A caller that sees "body-markup" sends pango,
// and no surface renders it.
@(private = "file")
on_capabilities :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context
	return reply_strings(message, {"body", "actions", "persistence"}, true)
}

@(private = "file")
on_server_information :: proc "c" (message: ^Bus_Message, user: rawptr, error: rawptr) -> c.int {
	context = callback_context
	return reply_strings(message, {"kippbus", "kippbus", "1", "1.2"}, false)
}

@(private = "file")
reply_strings :: proc(call: ^Bus_Message, values: []cstring, as_array: bool) -> c.int {
	reply: ^Bus_Message
	if bus_message_new_method_return(call, &reply) < 0 do return -22
	defer bus_message_unref(reply)

	if as_array && bus_message_open_container(reply, 'a', "s") < 0 do return -22
	for value in values do bus_message_append_basic(reply, 's', rawptr(value))
	if as_array do bus_message_close_container(reply)
	bus_send(connection, reply, nil)
	return 1
}

// ------------------------------------------------------------- requests

@(private = "file")
// (hole notify-invoke :tags bus) no action=invoke: a bar cannot send ActionInvoked back to the app that sent the notification.
take_request :: proc(line: string) {
	payload := payload_of(line)
	switch payload["action"] {
	case "close":
		identifier, parsed := strconv.parse_u64(payload["id"])
		if !parsed || !close_note(u32(identifier), CLOSED_DISMISSED) {
			refuse("notif", "close takes the id= of a live notification", line)
		}
	case "read":
		for &note in notes {
			if note.read do continue
			note.read = true
			print_note(note)
		}
	case:
		refuse("notif", "unknown action", line)
	}
}

// ----------------------------------------------------------------- start

notify_start :: proc(arguments: []string) -> (Handlers, bool) {
	name := len(arguments) > 0 ? arguments[0] : NOTIFY_NAME
	if !open_bus(false) do return {}, false

	@(static) vtable: [7]Vtable
	vtable = {
		vtable_start(),
		vtable_method("Notify", "susssasa{sv}i", "u", on_notify),
		vtable_method("CloseNotification", "u", "", on_close),
		vtable_method("GetCapabilities", "", "as", on_capabilities),
		vtable_method("GetServerInformation", "", "ssss", on_server_information),
		vtable_signal("NotificationClosed", "uu"),
		vtable_end(),
	}
	if result := bus_add_object_vtable(connection, nil, NOTIFY_PATH, NOTIFY_INTERFACE,
	                                   &vtable[0], nil); result < 0 {
		fmt.eprintfln(
`kippbus: could not export the notification interface (%d), so nothing will
         reach the panel. [E-name] See DIAGNOSTICS.md.`, result)
		return {}, false
	}

	if bus_request_name(connection, cstr(name), 0) < 0 {
		fmt.eprintfln(
`kippbus: %s is already owned by another program, so no notification will
         reach the panel. Stop whatever holds it -- dunst, mako, a desktop
         shell -- then restart kippsrv. [E-name] See DIAGNOSTICS.md.`, name)
		return {}, false
	}
	return {on_line = take_request}, true
}
