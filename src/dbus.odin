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
// Reading the bus is these 15 symbols. Calling out and owning a name add
// twelve more, below. Nothing else in kippsrv touches the bus, and a source
// that polls `busctl` instead needs none of it:
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

	// Calling out. The only thing a consumer cannot do for itself, because
	// the connection an item registered on is this process's.
	bus_message_new_method_call :: proc(bus: ^Bus, m: ^^BMsg, dest, path, iface, member: cstring) -> c.int ---
	bus_message_set_expect_reply :: proc(m: ^BMsg, b: c.int) -> c.int ---

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

// Every integer D-Bus carries, as one. The wire type says how wide it is and
// whether it is signed, and nothing above this cares.
@(private = "file")
r_int :: proc(m: ^BMsg, t: u8) -> (v: i64, ok: bool) {
	switch t {
	case 'y': x: u8;  bus_message_read_basic(m, t, &x); v = i64(x)
	case 'b': x: b32; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'n': x: i16; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'q': x: u16; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'i': x: i32; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'u': x: u32; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'h': x: u32; bus_message_read_basic(m, t, &x); v = i64(x)
	case 'x', 't': x: i64; bus_message_read_basic(m, t, &x); v = x
	case: return 0, false
	}
	return v, true
}

// A dictionary key is any basic type, not a string only. bluez sends
// ManufacturerData as a{qv}, and reading a uint16 through a cstring builds a
// pointer out of two bytes of number, which segfaulted the daemon the moment
// anything nearby advertised. A JSON key is a string, so a number becomes one.
//
// A double key is legal on the wire and has no sensible JSON form. Refusing
// it drops that one message, which is what every other unreadable value does.
@(private = "file")
w_key :: proc(b: ^strings.Builder, m: ^BMsg, t: u8) -> bool {
	if t == 's' || t == 'o' || t == 'g' {
		x: cstring
		if bus_message_read_basic(m, t, &x) < 0 do return false
		w_str(b, string(x))
		return true
	}

	v := r_int(m, t) or_return
	buf: [24]byte
	strings.write_byte(b, '"')
	strings.write_string(b, strconv.write_int(buf[:], v, 10))
	strings.write_byte(b, '"')
	return true
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
		v, ok := r_int(m, t)
		if !ok do return false
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
				kt: u8
				kc: cstring
				if bus_message_peek_type(m, &kt, &kc) <= 0 do return false
				w_key(b, m, kt) or_return
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
		fmt.eprintfln(
`kippsrv: source %q cannot reach the %s bus (%d), so whatever it reports will
         be missing. [E-bus] See DIAGNOSTICS.md.`,
			name, system ? "system" : "session", r)
		return nil, false
	}

	for m in matches {
		cm := strings.clone_to_cstring(m, context.temp_allocator)
		if e := bus_add_match(bus, nil, cm, nil, nil); e < 0 {
			fmt.eprintfln(
`kippsrv: source %q had a D-Bus match rule refused (%d), so some of what it
         watches will be missing. The rule was %q. [E-bus] See DIAGNOSTICS.md.`,
				name, e, m)
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
		// Stamped with the source, so its death can mark these stale, and
		// held back when the source is throttled.
		src_feed(vm, s, out, transmute([]byte)line)
	}
}

// ---------------------------------------------------------------- calling

// One argument, from text. D-Bus is typed and Lua has one number type, so
// the adapter says which type it meant and this reads the text as that.
@(private = "file")
append_arg :: proc(m: ^BMsg, ch: u8, text: string) -> bool {
	switch ch {
	case 's', 'o', 'g':
		// append_basic takes the string itself for these, not its address.
		return bus_message_append_basic(m, ch, rawptr(cstr(text))) >= 0
	case 'b':
		v := b32(text == "true" || text == "1")
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 'y':
		n, _ := strconv.parse_u64(text)
		v := u8(n)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 'i':
		n, _ := strconv.parse_i64(text)
		v := i32(n)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 'u':
		n, _ := strconv.parse_u64(text)
		v := u32(n)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 'x':
		v, _ := strconv.parse_i64(text)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 't':
		v, _ := strconv.parse_u64(text)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	case 'd':
		v, _ := strconv.parse_f64(text)
		return bus_message_append_basic(m, ch, rawptr(&v)) >= 0
	}
	return false   // a container needs a shape, and text does not carry one
}

// Call a method on the source's own bus.
//
// No reply is asked for. SPEC.md says a command that succeeds gets no answer
// and the facts that follow show what it did, so there is nothing to wait
// for, and an application that is slow to act cannot stall the loop.
dbus_call :: proc(s: ^Source, call: Cmd_Call) -> bool {
	if s == nil || s.bus == nil do return false
	if call.dest == "" || call.path == "" || call.iface == "" || call.member == "" {
		return false
	}
	if len(call.sig) != len(call.args) do return false

	m: ^BMsg
	if bus_message_new_method_call(s.bus, &m, cstr(call.dest), cstr(call.path),
	                               cstr(call.iface), cstr(call.member)) < 0 {
		return false
	}
	defer bus_message_unref(m)

	for i in 0 ..< len(call.sig) {
		if !append_arg(m, call.sig[i], call.args[i]) do return false
	}
	bus_message_set_expect_reply(m, 0)
	return bus_send(s.bus, m, nil) >= 0
}
