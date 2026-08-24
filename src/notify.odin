// org.freedesktop.Notifications.
//
// The same job watcher.odin does for the tray, for notifications: own a
// well-known name and answer the calls that arrive on it. `notify-send` has
// never heard of any particular daemon. It calls whoever holds the name, so
// holding it is the whole of being one.
//
// The split is watcher.odin's. Odin answers the protocol -- the name, the
// reply serials, the marshalling, the id -- and none of those need to ask Lua
// anything, so no caller ever waits on the VM. What a notification *is* is
// named in lua/notify/fdo.lua, the same way the tray's registrations are named
// in lua/tray/snw.lua.
//
// Two members past the spec live on an interface of our own. Closing is in the
// spec; being read is not, because a spec notification is a toast that appears
// whether you wanted it or not, and these are only ever read on purpose.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"

NOTIFY_NAME  :: "org.freedesktop.Notifications"
NOTIFY_PATH  :: "/org/freedesktop/Notifications"
NOTIFY_IFACE :: "org.freedesktop.Notifications"

// Ours, on the same object. A consumer reaches it the way it reaches
// CloseNotification, so the surface needs no second channel.
NOTIFY_OWN_IFACE :: "place.paths.kippsrv.Notifications"

// Reasons, from the spec's NotificationClosed signal.
CLOSED_EXPIRED   :: u32(1)
CLOSED_DISMISSED :: u32(2)
CLOSED_REQUESTED  :: u32(3)

// ----------------------------------------------------------------- state

Note :: struct {
	id:      u32,
	app:     string,
	icon:    string,
	summary: string,
	body:    string,
	urgency: u8,      // 0 low, 1 normal, 2 critical. The spec's own numbering
	action:  string,  // the first action's key, which is what Return runs
	read:    bool,
}

Notifier :: struct {
	bus:     ^Bus,
	live:    [dynamic]Note,
	dropped: [dynamic]u32,   // closed, and the store must be told
	next:    u32,
	dirty:   bool,
}

@(private = "file")
n: Notifier

@(private = "file")
note_free :: proc(x: Note) {
	delete(x.app); delete(x.icon); delete(x.summary); delete(x.body); delete(x.action)
}

@(private = "file")
find :: proc(id: u32) -> int {
	for note, i in n.live do if note.id == id do return i
	return -1
}

// Drop it, tell whoever asked, and leave the id behind so the store learns the
// fact is gone rather than merely stale.
@(private = "file")
close_note :: proc(id: u32, reason: u32) -> bool {
	i := find(id)
	if i < 0 do return false

	note_free(n.live[i])
	ordered_remove(&n.live, i)
	append(&n.dropped, id)
	n.dirty = true
	emit_closed(id, reason)
	return true
}

// ------------------------------------------------------------- the hints
//
// a{sv}. Only two keys change what a fact says: urgency, and an icon the
// caller passed here instead of in app_icon. Everything else is skipped
// without being read, which is what the variant's own length is for.

@(private = "file")
read_hints :: proc(m: ^BMsg, note: ^Note) {
	if bus_message_enter_container(m, 'a', "{sv}") < 0 do return
	defer bus_message_exit_container(m)

	for {
		if bus_message_enter_container(m, 'e', "sv") <= 0 do break

		key: cstring
		if bus_message_read_basic(m, 's', &key) < 0 {
			bus_message_exit_container(m)
			break
		}
		name := string(key)

		if bus_message_enter_container(m, 'v', nil) > 0 {
			t: u8
			contents: cstring
			if bus_message_peek_type(m, &t, &contents) > 0 {
				switch {
				case name == "urgency" && t == 'y':
					v: u8
					if bus_message_read_basic(m, 'y', &v) >= 0 do note.urgency = v
				case (name == "image-path" || name == "image_path") && t == 's':
					v: cstring
					if bus_message_read_basic(m, 's', &v) >= 0 && note.icon == "" {
						note.icon = strings.clone(string(v))
					}
				}
			}
			bus_message_exit_container(m)
		}
		bus_message_exit_container(m)
	}
}

// as. The spec pairs them: key, label, key, label. Return runs one thing, so
// only the first key is kept and the labels are not ours to draw.
@(private = "file")
read_actions :: proc(m: ^BMsg) -> string {
	first := ""
	if bus_message_enter_container(m, 'a', "s") < 0 do return first
	defer bus_message_exit_container(m)

	i := 0
	for {
		s: cstring
		if bus_message_read_basic(m, 's', &s) <= 0 do break
		if i == 0 do first = strings.clone(string(s))
		i += 1
	}
	return first
}

// ------------------------------------------------------------- callbacks

@(private = "file")
on_notify :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	app, icon, summary, body: cstring
	replaces: u32
	timeout: i32

	if bus_message_read_basic(m, 's', &app) < 0 do return -22
	if bus_message_read_basic(m, 'u', &replaces) < 0 do return -22
	if bus_message_read_basic(m, 's', &icon) < 0 do return -22
	if bus_message_read_basic(m, 's', &summary) < 0 do return -22
	if bus_message_read_basic(m, 's', &body) < 0 do return -22

	note := Note{
		app     = strings.clone(str_or(app)),
		icon    = strings.clone(str_or(icon)),
		summary = strings.clone(str_or(summary)),
		body    = strings.clone(str_or(body)),
		urgency = 1,
	}
	note.action = read_actions(m)
	read_hints(m, &note)
	bus_message_read_basic(m, 'i', &timeout)

	// A replacement keeps its place in the list, so a progress notification
	// does not walk down the panel as it updates.
	if replaces != 0 {
		if i := find(replaces); i >= 0 {
			note.id = replaces
			note.read = n.live[i].read
			note_free(n.live[i])
			n.live[i] = note
			n.dirty = true
			reply_id(m, replaces)
			return 1
		}
	}

	note.id = n.next
	n.next += 1
	append(&n.live, note)
	n.dirty = true

	reply_id(m, note.id)
	return 1
}

@(private = "file")
on_close :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	id: u32
	if bus_message_read_basic(m, 'u', &id) < 0 do return -22
	close_note(id, CLOSED_REQUESTED)
	notify_reply_ok(m)
	return 1
}

// Ours. The panel says it once when it opens, and the bar's [!] becomes [N].
@(private = "file")
on_mark_read :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	for &note in n.live {
		if !note.read {
			note.read = true
			n.dirty = true
		}
	}
	notify_reply_ok(m)
	return 1
}

@(private = "file")
on_capabilities :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	reply: ^BMsg
	if bus_message_new_method_return(m, &reply) < 0 do return -22
	defer bus_message_unref(reply)

	// What we do, and nothing we do not. A caller that sees "body-markup"
	// here will send pango, and no surface renders it.
	if bus_message_open_container(reply, 'a', "s") < 0 do return -22
	for cap in ([]cstring{"body", "actions", "persistence"}) {
		bus_message_append_basic(reply, 's', rawptr(cap))
	}
	bus_message_close_container(reply)
	bus_send(n.bus, reply, nil)
	return 1
}

@(private = "file")
on_server_info :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	reply: ^BMsg
	if bus_message_new_method_return(m, &reply) < 0 do return -22
	defer bus_message_unref(reply)

	for s in ([]cstring{"kippsrv", "tildesh", "1", "1.2"}) {
		bus_message_append_basic(reply, 's', rawptr(s))
	}
	bus_send(n.bus, reply, nil)
	return 1
}

// ---------------------------------------------------------------- replies

@(private = "file")
notify_reply_ok :: proc(call: ^BMsg) {
	reply: ^BMsg
	if bus_message_new_method_return(call, &reply) < 0 do return
	defer bus_message_unref(reply)
	bus_send(n.bus, reply, nil)
}

@(private = "file")
reply_id :: proc(call: ^BMsg, id: u32) {
	reply: ^BMsg
	if bus_message_new_method_return(call, &reply) < 0 do return
	defer bus_message_unref(reply)

	v := id
	bus_message_append_basic(reply, 'u', rawptr(&v))
	bus_send(n.bus, reply, nil)
}

@(private = "file")
emit_closed :: proc(id: u32, reason: u32) {
	if n.bus == nil do return

	msg: ^BMsg
	r := bus_message_new_signal(n.bus, &msg, NOTIFY_PATH, NOTIFY_IFACE,
	                            "NotificationClosed")
	if r < 0 do return
	defer bus_message_unref(msg)

	a, b := id, reason
	bus_message_append_basic(msg, 'u', rawptr(&a))
	bus_message_append_basic(msg, 'u', rawptr(&b))
	bus_send(n.bus, msg, nil)
}

// ----------------------------------------------------------------- start

notify_start :: proc(d: ^Source, name := NOTIFY_NAME) -> bool {
	if n.bus != nil {
		fmt.eprintfln(
`kippsrv: already own a notification name, so %q was refused. Only the first
         one in config.lua starts. [E-name] See DIAGNOSTICS.md.`, name)
		return false
	}
	n.bus = d.bus
	n.live = make([dynamic]Note)
	n.dropped = make([dynamic]u32)
	// 0 means "no replacement" in the protocol, so it is never an id.
	n.next = 1
	n.dirty = true

	vt := make([]Vtable, 8)
	vt[0] = {head = vt_head(VT_START, 0)}
	vt[0].x.start.element_size = size_of(Vtable)
	when !#config(BASU, false) {
		vt[0].x.start.vtable_format_reference = &sd_bus_object_vtable_format
	}
	vt[1] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[1].x.method = {member = "Notify", signature = "susssasa{sv}i",
	                  result = "u", handler = on_notify}
	vt[2] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[2].x.method = {member = "CloseNotification", signature = "u",
	                  result = "", handler = on_close}
	vt[3] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[3].x.method = {member = "GetCapabilities", signature = "",
	                  result = "as", handler = on_capabilities}
	vt[4] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[4].x.method = {member = "GetServerInformation", signature = "",
	                  result = "ssss", handler = on_server_info}
	vt[5] = {head = vt_head(VT_SIGNAL, 0)}
	vt[5].x.signal = {member = "NotificationClosed", signature = "uu"}
	vt[6] = {head = vt_head(VT_SIGNAL, 0)}
	vt[6].x.signal = {member = "ActionInvoked", signature = "us"}
	vt[7] = {head = vt_head(VT_END, 0)}

	if r := bus_add_object_vtable(d.bus, nil, NOTIFY_PATH, NOTIFY_IFACE,
	                              raw_data(vt), nil); r < 0 {
		fmt.eprintfln(
`kippsrv: could not export the notification interface (%d), so nothing will
         reach the panel. [E-name] See DIAGNOSTICS.md.`, r)
		return false
	}

	own := make([]Vtable, 3)
	own[0] = {head = vt_head(VT_START, 0)}
	own[0].x.start.element_size = size_of(Vtable)
	when !#config(BASU, false) {
		own[0].x.start.vtable_format_reference = &sd_bus_object_vtable_format
	}
	own[1] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	own[1].x.method = {member = "MarkAllRead", signature = "", result = "",
	                   handler = on_mark_read}
	own[2] = {head = vt_head(VT_END, 0)}
	bus_add_object_vtable(d.bus, nil, NOTIFY_PATH, NOTIFY_OWN_IFACE,
	                      raw_data(own), nil)

	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if r := bus_request_name(n.bus, cname, 0); r < 0 {
		fmt.eprintfln(
`kippsrv: %s is already owned by another program, so no notification will
         reach the panel. Stop whatever holds it -- dunst, mako, a desktop
         shell -- then restart kippsrv. [E-name] See DIAGNOSTICS.md.`, name)
		return false
	}
	fmt.eprintfln("notify: owning %s", name)
	return true
}

// What is live, as one JSON line for an adapter to name. Same contract as
// watcher_pass: these are facts about a D-Bus interface, and the kind they
// become is lua/notify/fdo.lua's to decide.
notify_pass :: proc(vm: ^Vm, a: Adapter, out: ^[dynamic]Emit, src: int) {
	if n.bus == nil || !n.dirty do return
	n.dirty = false

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"live\":[")
	for note, i in n.live {
		if i > 0 do strings.write_byte(&b, ',')
		// A brace is a verb to Odin's fmt, so the object opens by hand.
		strings.write_byte(&b, '{')
		fmt.sbprintf(&b, "\"id\":%d,\"urgency\":%d,\"read\":%t,\"app\":",
		             note.id, note.urgency, note.read)
		strings.write_quoted_string(&b, note.app)
		strings.write_string(&b, ",\"summary\":")
		strings.write_quoted_string(&b, note.summary)
		strings.write_string(&b, ",\"body\":")
		strings.write_quoted_string(&b, note.body)
		strings.write_string(&b, ",\"icon\":")
		strings.write_quoted_string(&b, note.icon)
		strings.write_string(&b, ",\"action\":")
		strings.write_quoted_string(&b, note.action)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "],\"dropped\":[")
	for id, i in n.dropped {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, "%d", id)
	}
	strings.write_string(&b, "]}")

	for e in vm_feed(vm, a, strings.to_string(b)) {
		append(out, Emit{strings.clone(e.line, context.temp_allocator), e.kind, src})
	}
	clear(&n.dropped)
}
