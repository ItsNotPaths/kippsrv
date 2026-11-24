// kippbus: one D-Bus connection, run by kippsrv as an exec source. Lines go
// out on stdout and requests come in on stdin.
//
//   kippbus match [--system] [--names <namespace> [--each <call>]] <rule>...
//                                        each matching signal as JSON
//   kippbus tray [<name>]                owns the StatusNotifierWatcher
//   kippbus notify [<name>]              owns org.freedesktop.Notifications
//
// <name> owns a different name, for testing beside a live one.
package kippbus

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

MAX_INPUT :: 64 * 1024   // input with no newline must not grow without end

connection: ^Bus
callback_context: runtime.Context   // a C callback has no Odin context of its own

Handlers :: struct {
	on_message: proc(message: ^Bus_Message),   // a message no vtable answered
	on_line:    proc(line: string),            // one line of stdin
}

main :: proc() {
	callback_context = context
	if len(os.args) < 2 do usage()

	arguments := os.args[2:]
	handlers: Handlers
	started: bool
	switch os.args[1] {
	case "match":  handlers, started = match_start(arguments)
	case "tray":   handlers, started = tray_start(arguments)
	case "notify": handlers, started = notify_start(arguments)
	case:          usage()
	}
	if !started do os.exit(1)
	os.exit(run(handlers))
}

@(private = "file")
usage :: proc() -> ! {
	fmt.eprintln("usage: kippbus match [--system] [--names <namespace> [--each <call>]] <rule>... | tray [<name>] | notify [<name>]")
	os.exit(2)
}

open_bus :: proc(system: bool) -> bool {
	result := system ? bus_default_system(&connection) : bus_default_user(&connection)
	if result < 0 || connection == nil {
		fmt.eprintfln(
`kippbus: cannot reach the %s bus (%d), so whatever this source reports will
         be missing. [E-bus] See DIAGNOSTICS.md.`, system ? "system" : "session", result)
		return false
	}
	return true
}

// Until stdin closes, which is kippsrv letting go, or the bus drops.
@(private = "file")
run :: proc(handlers: Handlers) -> int {
	input := make([dynamic]byte)
	for {
		if !dispatch(handlers) {
			fmt.eprintln("kippbus: the bus connection dropped. [E-bus] See DIAGNOSTICS.md.")
			return 1
		}
		watched := [2]posix.pollfd{
			{fd = posix.STDIN_FILENO, events = {.IN}},
			{fd = posix.FD(bus_get_fd(connection)),
			 events = transmute(posix.Poll_Event)i16(bus_get_events(connection))},
		}
		if posix.poll(&watched[0], 2, -1) < 0 && posix.errno() != .EINTR do return 1
		if watched[0].revents != {} && !read_input(&input, handlers.on_line) do return 0
		free_all(context.temp_allocator)
	}
}

// Every message waiting.
@(private = "file")
dispatch :: proc(handlers: Handlers) -> bool {
	for {
		message: ^Bus_Message
		result := bus_process(connection, &message)
		if result < 0 do return false
		if result == 0 do return true
		if message == nil do continue
		if handlers.on_message != nil do handlers.on_message(message)
		bus_message_unref(message)
	}
}

// One read, then every whole line in it. false at the end of input.
@(private = "file")
read_input :: proc(input: ^[dynamic]byte, on_line: proc(line: string)) -> bool {
	chunk: [4096]byte
	count := int(posix.read(posix.STDIN_FILENO, raw_data(chunk[:]), len(chunk)))
	if count < 0 do return posix.errno() == .EINTR
	if count == 0 do return false

	if len(input) + count > MAX_INPUT {
		fmt.eprintfln("kippbus: over %d bytes of input with no newline were discarded.", MAX_INPUT)
		clear(input)
	}
	append(input, ..chunk[:count])
	for {
		end := strings.index_byte(string(input[:]), '\n')
		if end < 0 do return true
		if on_line != nil do on_line(string(input[:end]))
		remove_range(input, 0, end + 1)
	}
}

// One write per line, so kippsrv never reads half of one.
write_line :: proc(line: string) {
	text := strings.concatenate({line, "\n"}, context.temp_allocator)
	posix.write(posix.STDOUT_FILENO, raw_data(text), uint(len(text)))
}

// ------------------------------------------------------------------ kipp

// A tab or a newline would end the field or the line early.
@(private = "file")
write_clean :: proc(builder: ^strings.Builder, text: string) {
	for index in 0 ..< len(text) {
		character := text[index]
		strings.write_byte(builder, character < 0x20 || character == 0x7f ? ' ' : character)
	}
}

// `retain <topic>`, with fields to follow from add_field. A retain needs one.
begin_retain :: proc(builder: ^strings.Builder, topic: string) {
	strings.write_string(builder, "retain\t")
	write_clean(builder, topic)
}

// `delete <topic>`. A delete has no fields.
begin_delete :: proc(builder: ^strings.Builder, topic: string) {
	strings.write_string(builder, "delete\t")
	write_clean(builder, topic)
}

add_field :: proc(builder: ^strings.Builder, key, value: string) {
	strings.write_byte(builder, '\t')
	strings.write_string(builder, key)
	strings.write_byte(builder, '=')
	write_clean(builder, value)
}

// The key=value fields of a kipp line, past the verb and the topic.
payload_of :: proc(line: string) -> map[string]string {
	payload := make(map[string]string, allocator = context.temp_allocator)
	fields := strings.split(line, "\t", context.temp_allocator)
	for field in fields[min(2, len(fields)):] {
		key, equals, value := strings.partition(field, "=")
		if equals != "" do payload[key] = value
	}
	return payload
}

refuse :: proc(what, reason, line: string) {
	fmt.eprintfln("kippbus: a %s request was dropped: %s. The line was %q.", what, reason, line)
}
