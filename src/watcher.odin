// org.kde.StatusNotifierWatcher.
//
// Owning a well-known name is the one thing `busctl` cannot do for us. A tray
// application looks for this name once, at its own startup: if nobody owns it,
// no icon ever registers.
//
// The kind those registrations become is named in lua/tray/snw.lua, not here.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"

WATCHER_NAME  :: "org.kde.StatusNotifierWatcher"
WATCHER_PATH  :: "/StatusNotifierWatcher"
WATCHER_IFACE :: "org.kde.StatusNotifierWatcher"

// ----------------------------------------------------------- the vtable
//
// libsystemd is 56 bytes and carries parameter names and a format reference.
// basu is 48 and does not. sd_bus_add_object_vtable rejects a mismatch at run
// time, so the layout follows the same switch as the library.

when #config(BASU, false) {
	VT_Start :: struct {
		element_size: uint,
	}
	VT_Method :: struct {
		member, signature, result: cstring,
		handler:                   Bus_Handler,
		offset:                    uint,
	}
	VT_Signal :: struct {
		member, signature: cstring,
	}
} else {
	VT_Start :: struct {
		element_size:            uint,
		features:                u64,
		vtable_format_reference: ^u32,
	}
	VT_Method :: struct {
		member, signature, result: cstring,
		handler:                   Bus_Handler,
		offset:                    uint,
		names:                     cstring,
	}
	VT_Signal :: struct {
		member, signature, names: cstring,
	}
}

VT_Property :: struct {
	member, signature: cstring,
	get:               Bus_Prop_Get,
	set:               rawptr,
	offset:            uint,
}

Vtable :: struct {
	// type in the low 8 bits, flags in the 56 above it
	head: u64,
	x:    struct #raw_union {
		start:    VT_Start,
		method:   VT_Method,
		signal:   VT_Signal,
		property: VT_Property,
	},
}

Bus_Handler  :: #type proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int
Bus_Prop_Get :: #type proc "c" (bus: ^Bus, path, iface, prop: cstring,
                                reply: ^BMsg, user: rawptr, err: rawptr) -> c.int

VT_START  :: 0x3c   // '<'
VT_END    :: 0x3e   // '>'
VT_METHOD :: 0x4d   // 'M'
VT_SIGNAL :: 0x53   // 'S'
VT_PROP   :: 0x50   // 'P'

PROPERTY_EMITS_CHANGE :: u64(1) << 5
UNPRIVILEGED          :: u64(1) << 2

// Shared with notify.odin: the vtable layout is the bus library's, not any one
// protocol's, so the second server built on it uses the same head.
vt_head :: proc(type: u64, flags: u64) -> u64 {
	return type | (flags << 8)
}

// -------------------------------------------------------------- the state

Watcher :: struct {
	bus:     ^Bus,
	items:   [dynamic]string,   // "service/path" as the protocol gives them
	dropped: [dynamic]string,   // left the bus, and the store must be told
	hosts:   [dynamic]string,   // bus names, so one that exits stops counting
	dirty:   bool,            // something changed, so the adapter is owed a line
}

@(private = "file")
w: Watcher

@(private = "file")
have_item :: proc(s: string) -> bool {
	for it in w.items do if it == s do return true
	return false
}

// ------------------------------------------------------------- callbacks

@(private = "file")
on_register_item :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	arg: cstring
	if bus_message_read_basic(m, 's', &arg) < 0 do return -22

	// The protocol allows either a bus name or an object path. A name that
	// starts with '/' is a path on the sender's own connection.
	svc := string(arg)
	sender := str_or(bus_message_get_sender(m))
	full := strings.has_prefix(svc, "/") \
		? fmt.aprintf("%s%s", sender, svc) \
		: fmt.aprintf("%s/StatusNotifierItem", svc)

	if have_item(full) {
		delete(full)
	} else {
		append(&w.items, full)
		changed()
		emit_signal_s("StatusNotifierItemRegistered", full)
	}
	reply_ok(m)
	return 1
}

@(private = "file")
on_register_host :: proc "c" (m: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	arg: cstring
	bus_message_read_basic(m, 's', &arg)

	who := str_or(bus_message_get_sender(m))
	for h in w.hosts do if h == who do break
	append(&w.hosts, strings.clone(who))
	changed()
	emit_signal_s("StatusNotifierHostRegistered", "")
	reply_ok(m)
	return 1
}

// An empty reply, without going through the varargs entry point.
@(private = "file")
reply_ok :: proc(call: ^BMsg) {
	reply: ^BMsg
	if bus_message_new_method_return(call, &reply) < 0 do return
	defer bus_message_unref(reply)
	bus_send(w.bus, reply, nil)
}

@(private = "file")
get_items :: proc "c" (bus: ^Bus, path, iface, prop: cstring,
                       reply: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx

	if bus_message_open_container(reply, 'a', "s") < 0 do return -22
	for it in w.items {
		cs := strings.clone_to_cstring(it, context.temp_allocator)
		bus_message_append_basic(reply, 's', rawptr(cs))
	}
	bus_message_close_container(reply)
	return 1
}

@(private = "file")
get_host_registered :: proc "c" (bus: ^Bus, path, iface, prop: cstring,
                                 reply: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx
	v := b32(len(w.hosts) > 0)
	bus_message_append_basic(reply, 'b', rawptr(&v))
	return 1
}

@(private = "file")
get_protocol_version :: proc "c" (bus: ^Bus, path, iface, prop: cstring,
                                  reply: ^BMsg, user: rawptr, err: rawptr) -> c.int {
	context = odin_ctx
	v := i32(0)
	bus_message_append_basic(reply, 'i', rawptr(&v))
	return 1
}

@(private = "file")
emit_signal_s :: proc(member: string, arg: string) {
	msg: ^BMsg
	cm := strings.clone_to_cstring(member, context.temp_allocator)
	if bus_message_new_signal(w.bus, &msg, WATCHER_PATH, WATCHER_IFACE, cm) < 0 do return
	defer bus_message_unref(msg)

	if arg != "" {
		cs := strings.clone_to_cstring(arg, context.temp_allocator)
		// append_basic takes the string itself for 's'. read_basic takes the
		// address of a pointer. They are not symmetric.
		bus_message_append_basic(msg, 's', rawptr(cs))
	}
	bus_send(w.bus, msg, nil)
}

// An application that exits does not unregister, so this is the only notice.
watcher_notice :: proc(m: ^BMsg) {
	if w.bus == nil do return
	if str_or(bus_message_get_member(m)) != "NameOwnerChanged" do return

	name, old_owner, new_owner: cstring
	if bus_message_read_basic(m, 's', &name) < 0 do return
	if bus_message_read_basic(m, 's', &old_owner) < 0 do return
	if bus_message_read_basic(m, 's', &new_owner) < 0 do return
	if new_owner != nil && len(string(new_owner)) > 0 do return   // it moved, not left

	// The separator matters. ":1.4" is a prefix of ":1.42/..." and unique
	// names are handed out in sequence, so neighbours collide.
	gone := strings.concatenate({string(name), "/"}, context.temp_allocator)
	for i := 0; i < len(w.items); i += 1 {
		if !strings.has_prefix(w.items[i], gone) do continue
		emit_signal_s("StatusNotifierItemUnregistered", w.items[i])
		// The store holds the last value of every fact. Ceasing to emit one
		// is not the same as retracting it, so say so.
		append(&w.dropped, w.items[i])
		ordered_remove(&w.items, i)
		i -= 1
		changed()
	}

	for i := 0; i < len(w.hosts); i += 1 {
		if w.hosts[i] != string(name) do continue
		delete(w.hosts[i])
		ordered_remove(&w.hosts, i)
		i -= 1
		changed()
	}
}

// The properties are declared as emitting PropertiesChanged. A client that
// waits for the signal rather than polling depends on it being sent.
@(private = "file")
changed :: proc() {
	w.dirty = true
	if w.bus == nil do return

	names := []cstring{"RegisteredStatusNotifierItems", "IsStatusNotifierHostRegistered", nil}
	bus_emit_properties_changed_strv(w.bus, WATCHER_PATH, WATCHER_IFACE, raw_data(names))
}

// ----------------------------------------------------------------- start

watcher_start :: proc(d: ^Source, name := WATCHER_NAME) -> bool {
	// One watcher. Its state is one table, so a second would answer the
	// first bus's calls from the second's list.
	if w.bus != nil {
		fmt.eprintfln(
`kippsrv: already own a watcher name, so %q was refused. Only the first
         watcher in config.lua starts. [E-name] See DIAGNOSTICS.md.`, name)
		return false
	}
	w.bus = d.bus
	w.items = make([dynamic]string)
	w.dropped = make([dynamic]string)
	w.hosts = make([dynamic]string)
	w.dirty = true

	vt := make([]Vtable, 10)
	vt[0] = {head = vt_head(VT_START, 0)}
	vt[0].x.start.element_size = size_of(Vtable)
	when !#config(BASU, false) {
		vt[0].x.start.vtable_format_reference = &sd_bus_object_vtable_format
	}
	vt[1] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[1].x.method = {member = "RegisterStatusNotifierItem", signature = "s",
	                  result = "", handler = on_register_item}
	vt[2] = {head = vt_head(VT_METHOD, UNPRIVILEGED)}
	vt[2].x.method = {member = "RegisterStatusNotifierHost", signature = "s",
	                  result = "", handler = on_register_host}
	vt[3] = {head = vt_head(VT_PROP, PROPERTY_EMITS_CHANGE)}
	vt[3].x.property = {member = "RegisteredStatusNotifierItems", signature = "as",
	                    get = get_items}
	vt[4] = {head = vt_head(VT_PROP, PROPERTY_EMITS_CHANGE)}
	vt[4].x.property = {member = "IsStatusNotifierHostRegistered", signature = "b",
	                    get = get_host_registered}
	vt[5] = {head = vt_head(VT_PROP, 0)}
	vt[5].x.property = {member = "ProtocolVersion", signature = "i",
	                    get = get_protocol_version}
	vt[6] = {head = vt_head(VT_SIGNAL, 0)}
	vt[6].x.signal = {member = "StatusNotifierItemRegistered", signature = "s"}
	vt[7] = {head = vt_head(VT_SIGNAL, 0)}
	vt[7].x.signal = {member = "StatusNotifierItemUnregistered", signature = "s"}
	vt[8] = {head = vt_head(VT_SIGNAL, 0)}
	vt[8].x.signal = {member = "StatusNotifierHostRegistered", signature = ""}
	vt[9] = {head = vt_head(VT_END, 0)}

	if r := bus_add_object_vtable(d.bus, nil, WATCHER_PATH, WATCHER_IFACE,
	                              raw_data(vt), nil); r < 0 {
		fmt.eprintfln(
`kippsrv: could not export the watcher interface (%d), so the tray will stay
         empty. [E-name] See DIAGNOSTICS.md.`, r)
		return false
	}

	// Notice when a registered application leaves the bus.
	bus_add_match(w.bus, nil,
	              "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'",
	              nil, nil)

	cname := strings.clone_to_cstring(name, context.temp_allocator)
	if r := bus_request_name(w.bus, cname, 0); r < 0 {
		fmt.eprintfln(
`kippsrv: %s is already owned by another program, so the tray will stay
         empty. Stop whatever holds it, then restart kippsrv and any
         application with a tray icon. [E-name] See DIAGNOSTICS.md.`, name)
		return false
	}
	fmt.eprintfln("watcher: owning %s", name)
	return true
}

// What is registered, as one JSON line for an adapter to name. "items" and
// "dropped" are facts about a D-Bus interface, not nouns of the desktop.
watcher_pass :: proc(vm: ^Vm, a: Adapter, out: ^[dynamic]Emit, src: int) {
	if w.bus == nil || !w.dirty do return
	w.dirty = false

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"items\":[")
	for it, i in w.items {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_quoted_string(&b, it)
	}
	strings.write_string(&b, "],\"dropped\":[")
	for it, i in w.dropped {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_quoted_string(&b, it)
	}
	strings.write_string(&b, "]}")

	for e in vm_feed(vm, a, strings.to_string(b)) {
		append(out, Emit{strings.clone(e.line, context.temp_allocator), e.kind, src})
	}
	for it in w.dropped do delete(it)
	clear(&w.dropped)
}
