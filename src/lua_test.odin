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
