// kippbus match: each signal a rule takes, as the JSON busctl prints, so one
// adapter works whether a fact was polled or pushed. stdin takes method calls,
// fields tab-separated as in kipp:
//
//   call <destination> <path> <interface> <member> <signature> <argument>...
//
// Arguments cross as text, and the signature says what each one is.
//
// --names <namespace> tracks the bus names under it, so an adapter keeps state
// instead of rebuilding it from signals:
//
//   {"type":"appeared","name":...}   on the bus at start, or arrived since
//   {"type":"left","name":...}       its facts are gone
//   "name" on every message          the watched name its sender owns
//
// --each <path> <interface> <member> [<signature> <argument>...] calls each
// name as it appears, space-separated, and prints the reply as a
// "method_return" in order with the signals.
package kippbus

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

@(private = "file") namespace: string
@(private = "file") each:      []string
// A connection's unique name, and the watched name it owns. A connection
// that owns two (vlc does) is named by the first.
@(private = "file") owners:    map[string]string

@(private = "file") METHOD_RETURN :: 2
@(private = "file") METHOD_ERROR  :: 3
@(private = "file") SIGNAL        :: 4

// `rules` are D-Bus match rules, the same strings busctl and dbus-monitor take.
match_start :: proc(arguments: []string) -> (Handlers, bool) {
	rules := arguments
	system := false
	flags: for len(rules) > 0 {
		switch {
		case rules[0] == "--system":
			system = true
			rules = rules[1:]
		case rules[0] == "--names" && len(rules) > 1:
			namespace = rules[1]
			rules = rules[2:]
		case rules[0] == "--each" && len(rules) > 1:
			each = strings.fields(rules[1])
			rules = rules[2:]
		case:
			break flags
		}
	}
	if !open_bus(system) do return {}, false

	for rule in rules do add_match(rule)
	if namespace != "" {
		add_match(fmt.tprintf("type='signal',sender='org.freedesktop.DBus'," +
		                      "member='NameOwnerChanged',arg0namespace='%s'", namespace))
		// After the match, so a name that arrives in between is seen twice, not missed.
		list_names()
	}
	return {on_message = print_message, on_line = take_call}, true
}

@(private = "file")
add_match :: proc(rule: string) {
	if result := bus_add_match(connection, nil, cstr(rule), nil, nil); result < 0 {
		fmt.eprintfln(
`kippbus: a match rule was refused (%d), so some of what this source watches
         will be missing. The rule was %q. [E-bus] See DIAGNOSTICS.md.`, result, rule)
	}
}

@(private = "file")
print_message :: proc(message: ^Bus_Message) {
	type: u8
	bus_message_get_type(message, &type)
	switch {
	case type == METHOD_ERROR:
		fmt.eprintfln("kippbus: %s refused the --each call.", owners[text_of(bus_message_get_sender(message))])
		return
	case type == SIGNAL && namespace != "" && owner_changed(message):
		return
	}
	line := message_json(message, type)
	if line != "" do write_line(line)
}

// ------------------------------------------------------------------ names

@(private = "file")
in_namespace :: proc(name: string) -> bool {
	return name == namespace ||
	       (strings.has_prefix(name, namespace) && strings.has_prefix(name[len(namespace):], "."))
}

// Every watched name already on the bus.
@(private = "file")
list_names :: proc() {
	reply, ok := call_method_and_wait("org.freedesktop.DBus", "/org/freedesktop/DBus",
	                                  "org.freedesktop.DBus", "ListNames", "", nil)
	if !ok do return
	names := make([dynamic]string, context.temp_allocator)
	if bus_message_enter_container(reply, 'a', "s") > 0 {
		for {
			name: cstring
			if bus_message_read_basic(reply, 's', &name) <= 0 do break
			if in_namespace(string(name)) do append(&names, strings.clone(string(name), context.temp_allocator))
		}
	}
	bus_message_unref(reply)

	for name in names {
		reply := call_method_and_wait("org.freedesktop.DBus", "/org/freedesktop/DBus",
		                              "org.freedesktop.DBus", "GetNameOwner", "s", {name}) or_continue
		owner: cstring
		if bus_message_read_basic(reply, 's', &owner) > 0 do appeared(name, string(owner))
		bus_message_unref(reply)
	}
}

// The bus daemon's NameOwnerChanged is ours while names are watched.
@(private = "file")
owner_changed :: proc(message: ^Bus_Message) -> bool {
	if text_of(bus_message_get_sender(message)) != "org.freedesktop.DBus" do return false
	if text_of(bus_message_get_member(message)) != "NameOwnerChanged" do return false

	name, old_owner, new_owner: cstring
	if bus_message_read_basic(message, 's', &name) < 0 do return true
	if bus_message_read_basic(message, 's', &old_owner) < 0 do return true
	if bus_message_read_basic(message, 's', &new_owner) < 0 do return true
	if !in_namespace(text_of(name)) do return true

	if text_of(old_owner) != "" do left(string(name), string(old_owner))
	if text_of(new_owner) != "" do appeared(string(name), string(new_owner))
	return true
}

@(private = "file")
appeared :: proc(name, owner: string) {
	if owner in owners do return
	owners[strings.clone(owner)] = strings.clone(name)
	write_name_line("appeared", name)

	if len(each) < 3 do return
	signature := each[3] if len(each) > 3 else ""
	arguments := each[4:] if len(each) > 4 else nil
	if !call_method_with_reply(name, each[0], each[1], each[2], signature, arguments) {
		fmt.eprintfln("kippbus: the --each call to %s would not send.", name)
	}
}

@(private = "file")
left :: proc(name, owner: string) {
	if owners[owner] != name do return
	key, value := delete_key(&owners, owner)
	delete(key)
	delete(value)
	write_name_line("left", name)
}

@(private = "file")
write_name_line :: proc(type, name: string) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"type\":")
	write_json_string(&builder, type)
	strings.write_string(&builder, ",\"name\":")
	write_json_string(&builder, name)
	strings.write_byte(&builder, '}')
	write_line(strings.to_string(builder))
}

@(private = "file")
take_call :: proc(line: string) {
	fields := strings.split(line, "\t", context.temp_allocator)
	if len(fields) < 5 || fields[0] != "call" {
		refuse("call", "it is not call <destination> <path> <interface> <member> <signature> <argument>...", line)
		return
	}
	signature := len(fields) > 5 ? fields[5] : ""
	arguments := len(fields) > 6 ? fields[6:] : nil
	if !call_method(fields[1], fields[2], fields[3], fields[4], signature, arguments) {
		refuse("call", "the bus would not take it", line)
	}
}

// ---------------------------------------------------------------- writing

@(private = "file")
write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index in 0 ..< len(text) {
		character := text[index]
		switch character {
		case '"':  strings.write_string(builder, "\\\"")
		case '\\': strings.write_string(builder, "\\\\")
		case '\n': strings.write_string(builder, "\\n")
		case '\t': strings.write_string(builder, "\\t")
		case '\r': strings.write_string(builder, "\\r")
		case:
			if character < 0x20 {
				hexadecimal := "0123456789abcdef"
				strings.write_string(builder, "\\u00")
				strings.write_byte(builder, hexadecimal[character >> 4])
				strings.write_byte(builder, hexadecimal[character & 0xf])
			} else {
				strings.write_byte(builder, character)
			}
		}
	}
	strings.write_byte(builder, '"')
}

// Every integer D-Bus carries, as one.
@(private = "file")
read_integer :: proc(message: ^Bus_Message, type: u8) -> (value: i64, ok: bool) {
	switch type {
	case 'y': raw: u8;  bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'b': raw: b32; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'n': raw: i16; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'q': raw: u16; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'i': raw: i32; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'u': raw: u32; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'h': raw: u32; bus_message_read_basic(message, type, &raw); value = i64(raw)
	case 'x', 't': bus_message_read_basic(message, type, &value)
	case: return 0, false
	}
	return value, true
}

// A dictionary key is any basic type. bluez sends ManufacturerData as a{qv},
// and reading a uint16 as a cstring segfaulted on anything that advertised.
// A JSON key is a string, so a number becomes one. A double key is refused.
@(private = "file")
write_key :: proc(builder: ^strings.Builder, message: ^Bus_Message, type: u8) -> bool {
	if type == 's' || type == 'o' || type == 'g' {
		text: cstring
		if bus_message_read_basic(message, type, &text) < 0 do return false
		write_json_string(builder, string(text))
		return true
	}

	value := read_integer(message, type) or_return
	digits: [24]byte
	strings.write_byte(builder, '"')
	strings.write_string(builder, strconv.write_int(digits[:], value, 10))
	strings.write_byte(builder, '"')
	return true
}

// One value, in the shape `busctl --json=short` prints: {"type":..,"data":..}
@(private = "file")
write_value :: proc(builder: ^strings.Builder, message: ^Bus_Message, depth := 0) -> bool {
	if depth > 16 do return false          // a malformed message must not recurse forever

	type: u8
	contents: cstring
	if bus_message_peek_type(message, &type, &contents) <= 0 do return false

	start := strings.builder_len(builder^)
	strings.write_string(builder, "{\"type\":")
	write_json_string(builder, string([]byte{type}))
	strings.write_string(builder, ",\"data\":")

	switch type {
	case 'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'h':
		value := read_integer(message, type) or_return
		if type == 'b' {
			strings.write_string(builder, value != 0 ? "true" : "false")
		} else {
			digits: [24]byte
			strings.write_string(builder, strconv.write_int(digits[:], value, 10))
		}

	case 'd':
		value: f64
		bus_message_read_basic(message, type, &value)
		if math.is_nan(value) || math.is_inf(value) {
			strings.write_string(builder, "null")   // JSON has no form for either
		} else {
			digits: [40]byte
			text := strconv.write_float(digits[:], value, 'g', -1, 64)
			strings.write_string(builder, strings.trim_prefix(text, "+"))   // Odin writes +1, JSON wants 1
		}

	case 's', 'o', 'g':
		text: cstring
		bus_message_read_basic(message, type, &text)
		write_json_string(builder, string(text))

	case 'a':
		// An array of pairs is a dictionary: an object, not a list.
		element := string(contents)
		dictionary := len(element) > 0 && element[0] == '{'
		if bus_message_enter_container(message, type, contents) <= 0 do return false
		strings.write_byte(builder, dictionary ? '{' : '[')
		first := true
		for {
			entry_type: u8
			entry_contents: cstring
			if bus_message_peek_type(message, &entry_type, &entry_contents) <= 0 do break
			if !first do strings.write_byte(builder, ',')
			first = false
			if dictionary {
				if bus_message_enter_container(message, entry_type, entry_contents) <= 0 do break
				key_type: u8
				key_contents: cstring
				if bus_message_peek_type(message, &key_type, &key_contents) <= 0 do return false
				write_key(builder, message, key_type) or_return
				strings.write_byte(builder, ':')
				write_value(builder, message, depth + 1) or_return
				bus_message_exit_container(message)
			} else {
				write_value(builder, message, depth + 1) or_return
			}
		}
		strings.write_byte(builder, dictionary ? '}' : ']')
		bus_message_exit_container(message)

	case 'v':
		// busctl collapses a variant to what it holds, so the wrapper this
		// call started is dropped and the contained value written instead.
		resize(&builder.buf, start)
		if bus_message_enter_container(message, type, contents) <= 0 do return false
		write_value(builder, message, depth + 1) or_return
		bus_message_exit_container(message)
		return true

	case 'r', '(':
		if bus_message_enter_container(message, 'r', contents) <= 0 do return false
		strings.write_byte(builder, '[')
		first := true
		for {
			entry_type: u8
			entry_contents: cstring
			if bus_message_peek_type(message, &entry_type, &entry_contents) <= 0 do break
			if !first do strings.write_byte(builder, ',')
			first = false
			write_value(builder, message, depth + 1) or_return
		}
		strings.write_byte(builder, ']')
		bus_message_exit_container(message)

	case:
		strings.write_string(builder, "null")
	}

	strings.write_byte(builder, '}')
	return true
}

// The whole message on one line, or "" if any value would not convert: half a
// document is worse than none.
@(private = "file")
message_json :: proc(message: ^Bus_Message, type: u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	sender := text_of(bus_message_get_sender(message))

	strings.write_string(&builder, "{\"type\":")
	write_json_string(&builder, type == METHOD_RETURN ? "method_return" : "signal")
	strings.write_string(&builder, ",\"sender\":")
	write_json_string(&builder, sender)
	strings.write_string(&builder, ",\"name\":")
	write_json_string(&builder, owners[sender])
	strings.write_string(&builder, ",\"path\":")
	write_json_string(&builder, text_of(bus_message_get_path(message)))
	strings.write_string(&builder, ",\"interface\":")
	write_json_string(&builder, text_of(bus_message_get_interface(message)))
	strings.write_string(&builder, ",\"member\":")
	write_json_string(&builder, text_of(bus_message_get_member(message)))
	strings.write_string(&builder, ",\"body\":[")

	first := true
	for {
		type: u8
		contents: cstring
		if bus_message_peek_type(message, &type, &contents) <= 0 do break
		if !first do strings.write_byte(&builder, ',')
		if !write_value(&builder, message) do return ""
		first = false
	}
	strings.write_string(&builder, "]}")
	return strings.to_string(builder)
}
