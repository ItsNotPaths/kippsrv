package kippsrv

import "core:fmt"
import "core:testing"

// The fence has to be a fact. If any of these names exists, a script can
// reach the filesystem, the network, or the loop.
@(test)
sandbox_is_closed :: proc(t: ^testing.T) {
	v, ok := vm_open()
	testing.expect(t, ok, "vm_open")
	defer vm_close(v)

	closed := []string{
		"io", "os", "package", "debug", "coroutine",
		"require", "dofile", "loadfile", "load",
	}
	for name in closed {
		src := fmt.tprintf("if %s ~= nil then error('%s exists') end", name, name)
		testing.expectf(t, vm_eval(v, src), "%s must not exist", name)
	}
}

@(test)
emit_joins_fields :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	testing.expect(t, vm_eval(v, `k.emit("tag", "eDP-1", "2", "state=focused")`))
	testing.expect_value(t, len(v.emitted), 1)
	testing.expect_value(t, v.emitted[0].line, "tag\teDP-1\t2\tstate=focused")
}

// A script hands over fields, never a line. So it cannot forge a second fact
// by putting a tab or a newline in a value.
@(test)
emit_cannot_forge_a_line :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	testing.expect(t, vm_eval(v, `k.emit("title", "0x1", "t=a\tb\nfocus\tHDMI-1")`))
	testing.expect_value(t, len(v.emitted), 1)
	testing.expect_value(t, v.emitted[0].line, "title\t0x1\tt=abfocusHDMI-1")
}

@(test)
parse_reaches_lua :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	testing.expect(t, vm_eval(v, `
		local m = k.parse("tag\teDP-1\t2\tstate=focused,occupied")
		if m.kind ~= "tag" then error("kind " .. tostring(m.kind)) end
		if m.subj[1] ~= "eDP-1" then error("subj1") end
		if m.subj[2] ~= "2" then error("subj2") end
		if m.attr.state ~= "focused,occupied" then error("attr") end
		if k.parse("") ~= nil then error("empty line should be nil") end
	`))
}

@(test)
parse_round_trips_the_wire :: proc(t: ^testing.T) {
	m, ok := parse("net\twifi\tssid=hotel guest\turl=a=b", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, m.kind, "net")
	testing.expect_value(t, m.attr["ssid"], "hotel guest")
	testing.expect_value(t, m.attr["url"], "a=b")

	// a leading @ field is reserved and skipped
	r, rok := parse("@t=1\tfocus\teDP-1", context.temp_allocator)
	testing.expect(t, rok)
	testing.expect_value(t, r.kind, "focus")
	testing.expect_value(t, len(r.subj), 1)
}

@(test)
adapter_turns_a_foreign_line_into_facts :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "lua/wm/example.lua")
	if !testing.expect(t, ok, "vm_load") do return
	defer vm_unload(v, a)

	out := vm_feed(v, a, "focus eDP-1 3")
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].line, "focus\teDP-1")
	testing.expect_value(t, out[1].line, "tag\teDP-1\t3\tstate=focused,occupied")

	// a line the adapter does not understand produces nothing
	testing.expect_value(t, len(vm_feed(v, a, "some other format")), 0)
}

@(test)
a_missing_adapter_fails_without_dying :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	_, ok := vm_load(v, "lua/wm/nothing-here.lua")
	testing.expect(t, !ok, "a missing file must fail, not crash")
}

// A script that never returns must not wedge the daemon. The sandbox keeps a
// descriptor out of a script, which is a different thing entirely.
@(test)
a_runaway_script_is_stopped :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "test/lua/runaway.lua")
	if !testing.expect(t, ok, "vm_load") do return
	defer vm_unload(v, a)

	out := vm_feed(v, a, "anything")     // returns rather than hanging
	testing.expect_value(t, len(out), 0)

	// and the VM still works afterwards
	testing.expect(t, vm_eval(v, `k.emit("after", "ok")`))
	testing.expect_value(t, len(v.emitted), 1)
}

// The step hook does not stop one greedy C call. `string.rep("x", 1e9)` is a
// single instruction to the VM, so the allocator cap is what stops it.
@(test)
a_greedy_script_is_stopped :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	before := v.mem.used
	testing.expect(t, !vm_eval(v, `local s = string.rep("x", 400000000)`),
	               "an allocation past the cap must fail the call")
	testing.expect(t, v.mem.used < MEM_CAP, "the cap held")

	// and the VM still works afterwards
	testing.expect(t, vm_eval(v, `k.emit("after", "ok")`))
	testing.expect_value(t, len(v.emitted), 1)
	testing.expect(t, v.mem.used < before + (1 << 20), "the memory came back")
}

// A subject holding '=' reads as the first attribute, so the fact keeps no
// subject and keys on its kind alone. That would overwrite every other fact
// of that kind, so it is refused rather than stored.
@(test)
a_subject_holding_equals_is_refused :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	testing.expect(t, vm_eval(v, `k.emit("net", "home=wifi", "type=wifi")`))
	testing.expect_value(t, len(v.emitted), 0)

	// the same name is fine in an attribute: only the first '=' separates
	testing.expect(t, vm_eval(v, `k.emit("net", "uuid-1", "name=home=wifi")`))
	testing.expect_value(t, len(v.emitted), 1)
	if len(v.emitted) == 1 {
		m, ok := parse(v.emitted[0].line, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, len(m.subj), 1)
		testing.expect_value(t, m.attr["name"], "home=wifi")
	}
}

// The outbound seam, with no source attached. An adapter answers in the terms
// its own source understands, and the core never learns what VIEW means.
@(test)
command_translates_for_its_own_source :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	a, ok := vm_load(v, "lua/wm/hedl.lua")
	if !testing.expect(t, ok, "vm_load") do return

	view, _ := parse("VIEW\t2", context.temp_allocator)
	bytes, is_bytes := vm_command(v, a, &view).(Cmd_Bytes)
	testing.expect(t, is_bytes, "VIEW answers with bytes")
	testing.expect_value(t, bytes.data, "view\t2\n")

	over, _ := parse("VIEW\t99", context.temp_allocator)
	bad, is_bad := vm_command(v, a, &over).(Cmd_Fail)
	testing.expect(t, is_bad, "a tag out of range is refused")
	testing.expect_value(t, bad.code, "badarg")

	// Another adapter's verb. Nothing at all, so the next source is asked.
	theirs, _ := parse("ACTIVATE\t:1.42/StatusNotifierItem", context.temp_allocator)
	testing.expect(t, vm_command(v, a, &theirs) == nil, "not its command")
}

// The tray is the case that cannot be done any other way: the connection the
// item registered on belongs to this process.
@(test)
command_describes_a_call :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	a, ok := vm_load(v, "lua/tray/snw.lua")
	if !testing.expect(t, ok, "vm_load") do return

	m, _ := parse("ACTIVATE\t:1.42/StatusNotifierItem\tx=10\ty=20",
	              context.temp_allocator)
	call, is_call := vm_command(v, a, &m).(Cmd_Call)
	if !testing.expect(t, is_call, "ACTIVATE answers with a call") do return

	testing.expect_value(t, call.dest, ":1.42")
	testing.expect_value(t, call.path, "/StatusNotifierItem")
	testing.expect_value(t, call.member, "Activate")
	testing.expect_value(t, call.sig, "ii")
	testing.expect_value(t, len(call.args), 2)
	testing.expect_value(t, call.args[0], "10")
	testing.expect_value(t, call.args[1], "20")
}
