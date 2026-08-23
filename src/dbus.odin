// D-Bus, through sd-bus.
//
// A signal becomes the JSON busctl already prints, so one adapter works
// whether a fact arrives by poll or by signal.
package kippsrv

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

Bus :: struct {}
BMsg :: struct {}

// libsystemd by default, basu with -define:BASU=true. Same API either way.
//
// The whole dependency is these 15 symbols. Nothing else in kippsrv touches
// the bus, and a source that polls `busctl` instead needs none of it:
//
//   sd_bus_default_user            sd_bus_message_get_path
//   sd_bus_default_system          sd_bus_message_get_interface
//   sd_bus_get_fd                  sd_bus_message_get_member
//   sd_bus_add_match               sd_bus_message_get_sender
//   sd_bus_process                 sd_bus_message_peek_type
//   sd_bus_unref                   sd_bus_message_read_basic
//   sd_bus_message_unref           sd_bus_message_enter_container
//                                  sd_bus_message_exit_container
when #config(BASU, false) {
	foreign import sdbus "system:basu"
} else {
	foreign import sdbus "system:systemd"
}

@(default_calling_convention = "c", link_prefix = "sd_")
foreign sdbus {
	bus_default_user            :: proc(ret: ^^Bus) -> c.int ---
	bus_default_system          :: proc(ret: ^^Bus) -> c.int ---
	bus_get_fd                  :: proc(bus: ^Bus) -> c.int ---
	bus_add_match               :: proc(bus: ^Bus, slot: rawptr, match: cstring, cb: rawptr, user: rawptr) -> c.int ---
	bus_process                 :: proc(bus: ^Bus, ret: ^^BMsg) -> c.int ---
	bus_unref                   :: proc(bus: ^Bus) -> ^Bus ---
	bus_message_unref           :: proc(m: ^BMsg) -> ^BMsg ---
	bus_message_get_path        :: proc(m: ^BMsg) -> cstring ---
	bus_message_get_interface   :: proc(m: ^BMsg) -> cstring ---
	bus_message_get_member      :: proc(m: ^BMsg) -> cstring ---
	bus_message_get_sender      :: proc(m: ^BMsg) -> cstring ---
	bus_message_peek_type       :: proc(m: ^BMsg, type: ^u8, contents: ^cstring) -> c.int ---
	bus_message_read_basic      :: proc(m: ^BMsg, type: u8, p: rawptr) -> c.int ---
	bus_message_enter_container :: proc(m: ^BMsg, type: u8, contents: cstring) -> c.int ---
	bus_message_exit_container  :: proc(m: ^BMsg) -> c.int ---

	// Owning a name and answering on it.
	bus_request_name            :: proc(bus: ^Bus, name: cstring, flags: u64) -> c.int ---
	bus_add_object_vtable       :: proc(bus: ^Bus, slot: rawptr, path, iface: cstring, vt: rawptr, user: rawptr) -> c.int ---
	// sd_bus_reply_method_return and sd_bus_emit_signal are varargs in C.
	// Calling a varargs function through a non-varargs declaration leaves
	// %al unset on x86-64, which is undefined and crashes. Build the reply
	// message instead: these two are not varargs.
	bus_message_new_method_return :: proc(call: ^BMsg, m: ^^BMsg) -> c.int ---
	bus_message_rewind            :: proc(m: ^BMsg, complete: b32) -> c.int ---
	bus_message_new_signal      :: proc(bus: ^Bus, m: ^^BMsg, path, iface, member: cstring) -> c.int ---
	bus_message_append_basic    :: proc(m: ^BMsg, type: u8, p: rawptr) -> c.int ---
	bus_message_open_container  :: proc(m: ^BMsg, type: u8, contents: cstring) -> c.int ---
	bus_message_close_container :: proc(m: ^BMsg) -> c.int ---
	bus_send                    :: proc(bus: ^Bus, m: ^BMsg, cookie: ^u64) -> c.int ---
	// _strv, not the varargs form, for the reason above.
	bus_emit_properties_changed_strv :: proc(bus: ^Bus, path, iface: cstring, names: [^]cstring) -> c.int ---
}

// libsystemd checks that a vtable was built against its own header by
// pointing at this. basu has no such check, and no such symbol.
when !#config(BASU, false) {
	@(default_calling_convention = "c")
	foreign sdbus {
		sd_bus_object_vtable_format: u32
	}
}

// A C callback has no Odin context. One is kept here for them to adopt.
odin_ctx: runtime.Context

// ---------------------------------------------------------------- writing

@(private = "file")
w_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\t': strings.write_string(b, "\\t")
		case '\r': strings.write_string(b, "\\r")
		case:
			if ch < 0x20 {
				hex := "0123456789abcdef"
				strings.write_string(b, "\\u00")
				strings.write_byte(b, hex[ch >> 4])
				strings.write_byte(b, hex[ch & 0xf])
			} else {
				strings.write_byte(b, ch)
			}
		}
	}
	strings.write_byte(b, '"')
}

// One value, in the shape `busctl --json=short` prints: {"type":..,"data":..}
@(private = "file")
w_value :: proc(b: ^strings.Builder, m: ^BMsg, depth := 0) -> bool {
	if depth > 16 do return false          // a malformed message must not recurse forever

	t: u8
	contents: cstring
	if bus_message_peek_type(m, &t, &contents) <= 0 do return false

	start := strings.builder_len(b^)
	strings.write_string(b, "{\"type\":")
	w_str(b, string([]byte{t}))
	strings.write_string(b, ",\"data\":")

	switch t {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'h':
		v: i64
		switch t {
		case 'y': x: u8;  bus_message_read_basic(m, t, &x); v = i64(x)
		case 'b': x: b32; bus_message_read_basic(m, t, &x); v = i64(x)
		case 'n': x: i16; bus_message_read_basic(m, t, &x); v = i64(x)
		case 'q': x: u16; bus_message_read_basic(m, t, &x); v = i64(x)
		case 'i': x: i32; bus_message_read_basic(m, t, &x); v = i64(x)
		case 'u': x: u32; bus_message_read_basic(m, t, &x); v = i64(x)
		case 'h': x: u32; bus_message_read_basic(m, t, &x); v = i64(x)
		case:     x: i64; bus_message_read_basic(m, t, &x); v = x
		}
		if t == 'b' {
			strings.write_string(b, v != 0 ? "true" : "false")
		} else {
			buf: [24]byte
			strings.write_string(b, strconv.write_int(buf[:], v, 10))
		}

	case 'd':
		x: f64
		bus_message_read_basic(m, t, &x)
		buf: [40]byte
		strings.write_string(b, strconv.write_float(buf[:], x, 'g', -1, 64))

	case 's', 'o', 'g':
		x: cstring
		bus_message_read_basic(m, t, &x)
		w_str(b, string(x))

	case 'a':
		// A dictionary is an array of pairs. JSON wants an object for one and
		// a list for the other, so the element type decides.
		cs := string(contents)
		dict := len(cs) > 0 && cs[0] == '{'
		if bus_message_enter_container(m, t, contents) <= 0 do return false
		strings.write_byte(b, dict ? '{' : '[')
		first := true
		for {
			et: u8
			ec: cstring
			if bus_message_peek_type(m, &et, &ec) <= 0 do break
			if !first do strings.write_byte(b, ',')
			first = false
			if dict {
				if bus_message_enter_container(m, et, ec) <= 0 do break
				key: cstring
				kt: u8
				kc: cstring
				bus_message_peek_type(m, &kt, &kc)
				bus_message_read_basic(m, kt, &key)
				w_str(b, string(key))
				strings.write_byte(b, ':')
				w_value(b, m, depth + 1) or_return
				bus_message_exit_container(m)
			} else {
				w_value(b, m, depth + 1) or_return
			}
		}
		strings.write_byte(b, dict ? '}' : ']')
		bus_message_exit_container(m)

	case 'v':
		// busctl collapses a variant to whatever it holds, and an adapter
		// should not have to know a value arrived wrapped. Drop the wrapper
		// this call started and write the contained value in its place.
		resize(&b.buf, start)
		if bus_message_enter_container(m, t, contents) <= 0 do return false
		w_value(b, m, depth + 1) or_return
		bus_message_exit_container(m)
		return true

	case 'r', '(':
		if bus_message_enter_container(m, 'r', contents) <= 0 do return false
		strings.write_byte(b, '[')
		first := true
		for {
			et: u8
			ec: cstring
			if bus_message_peek_type(m, &et, &ec) <= 0 do break
			if !first do strings.write_byte(b, ',')
			first = false
			w_value(b, m, depth + 1) or_return
		}
		strings.write_byte(b, ']')
		bus_message_exit_container(m)

	case:
		strings.write_string(b, "null")
	}

	strings.write_byte(b, '}')
	return true
}

// The whole signal, on one line.
@(private = "file")
w_message :: proc(m: ^BMsg, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	strings.write_string(&b, "{\"sender\":")
	w_str(&b, str_or(bus_message_get_sender(m)))
	strings.write_string(&b, ",\"path\":")
	w_str(&b, str_or(bus_message_get_path(m)))
	strings.write_string(&b, ",\"interface\":")
	w_str(&b, str_or(bus_message_get_interface(m)))
	strings.write_string(&b, ",\"member\":")
	w_str(&b, str_or(bus_message_get_member(m)))
	strings.write_string(&b, ",\"body\":[")

	first := true
	for {
		t: u8
		contents: cstring
		if bus_message_peek_type(m, &t, &contents) <= 0 do break
		mark := strings.builder_len(b)
		if !first do strings.write_byte(&b, ',')
		if !w_value(&b, m) {
			// Half a value would leave a trailing comma or an unbalanced
			// document. An adapter is better handed nothing.
			resize(&b.buf, mark)
			return ""
		}
		first = false
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

str_or :: proc(s: cstring) -> string {
	return s == nil ? "" : string(s)
}

// ----------------------------------------------------------------- source

// Connect and subscribe. `matches` are D-Bus match rules, the same strings
// busctl and dbus-monitor take.
dbus_open :: proc(ss: ^Sources, name: string, system: bool, matches: []string,
                  adapter: Adapter) -> (^Source, bool) {
	bus: ^Bus
	r := system ? bus_default_system(&bus) : bus_default_user(&bus)
	if r < 0 || bus == nil {
		fmt.eprintfln("dbus: %s: cannot reach the bus (%d)", name, r)
		return nil, false
	}

	for m in matches {
		cm := strings.clone_to_cstring(m, context.temp_allocator)
		if e := bus_add_match(bus, nil, cm, nil, nil); e < 0 {
			fmt.eprintfln("dbus: %s: match %q refused (%d)", name, m, e)
		}
	}

	odin_ctx = context

	return src_dbus(ss, name, bus, posix.FD(bus_get_fd(bus)), adapter), true
}

dbus_close :: proc(s: ^Source) {
	if s == nil || s.bus == nil do return
	bus_unref(s.bus)
	s.bus = nil
}

// Drain every message waiting and hand each to the adapter as one JSON line.
// false means the connection is gone, not that nothing was waiting.
dbus_ready :: proc(s: ^Source, vm: ^Vm, out: ^[dynamic]Emit) -> bool {
	for {
		m: ^BMsg
		r := bus_process(s.bus, &m)
		if r < 0 do return false
		if r == 0 do return true
		if m == nil do continue
		defer bus_message_unref(m)

		// The watcher tracks who is still on the bus. Reading a message
		// consumes it, so it is rewound before the adapter sees it.
		watcher_notice(m)
		bus_message_rewind(m, true)

		line := w_message(m, context.temp_allocator)
		if line == "" do continue      // the message would not convert
		for e in vm_feed(vm, s.adapter, line) {
			// stamped with the source, so its death can mark these stale
			append(out, Emit{strings.clone(e.line, context.temp_allocator), e.kind, s.id})
		}
	}
}
