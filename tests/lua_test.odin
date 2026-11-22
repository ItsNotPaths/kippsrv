package tests

import "core:fmt"
import "core:testing"
import kippsrv "../src"

// The fence has to be a fact. If any of these names exists, a script can
// reach the filesystem, the network, or the loop.
@(test)
sandbox_is_closed :: proc(t: ^testing.T) {
	v, ok := kippsrv.vm_open()
	testing.expect(t, ok, "vm_open")
	defer kippsrv.vm_close(v)

	closed := []string{
		"io", "os", "package", "debug", "coroutine",
		"require", "dofile", "loadfile", "load",
	}
	for name in closed {
		src := fmt.tprintf("if %s ~= nil then error('%s exists') end", name, name)
		testing.expectf(t, kippsrv.vm_eval(v, src), "%s must not exist", name)
	}
}

@(test)
retain_and_publish_build_lines :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	testing.expect(t, kippsrv.vm_eval(v, `
		k.retain("tag/eDP-1/2", "state=focused")
		k.publish("win_close/0x1")
	`))
	testing.expect_value(t, len(v.emitted), 2)
	testing.expect_value(t, v.emitted[0].line, "retain\ttag/eDP-1/2\tstate=focused")
	testing.expect_value(t, v.emitted[1].line, "publish\twin_close/0x1")
}

// A script hands over fields, never a line. So it cannot forge a second fact
// by putting a tab or a newline in a value.
@(test)
retain_cannot_forge_a_line :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	testing.expect(t, kippsrv.vm_eval(v, `k.retain("title/0x1", "t=a\tb\nfocus\tHDMI-1")`))
	testing.expect_value(t, len(v.emitted), 1)
	testing.expect_value(t, v.emitted[0].line, "retain\ttitle/0x1\tt=abfocusHDMI-1")
}

@(test)
parse_reaches_lua :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	testing.expect(t, kippsrv.vm_eval(v, `
		local m = k.parse("retain\ttag/eDP-1/2\tstate=focused,occupied")
		if m.verb ~= "retain" then error("verb " .. tostring(m.verb)) end
		if m.topic ~= "tag/eDP-1/2" then error("topic") end
		if m.payload.state ~= "focused,occupied" then error("payload") end
		if k.parse("") ~= nil then error("empty line should be nil") end
	`))
}

@(test)
parse_round_trips_the_wire :: proc(t: ^testing.T) {
	m, ok := kippsrv.parse("retain\tnet/wifi\tssid=hotel guest\turl=a=b", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, m.verb, "retain")
	testing.expect_value(t, m.topic, "net/wifi")
	testing.expect_value(t, m.payload["ssid"], "hotel guest")
	testing.expect_value(t, m.payload["url"], "a=b")

	// a field after the topic with no '=' is skipped
	r, rok := kippsrv.parse("publish\tfocus\teDP-1\tx=1", context.temp_allocator)
	testing.expect(t, rok)
	testing.expect_value(t, len(r.payload), 1)
}

@(test)
adapter_turns_a_foreign_line_into_facts :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	a, ok := kippsrv.vm_load(v, "sources.d/wm-example.lua")
	if !testing.expect(t, ok, "vm_load") do return
	defer kippsrv.vm_unload(v, a)

	out := kippsrv.vm_feed(v, a, "focus eDP-1 3")
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[0].line, "retain\tfocus\tmon=eDP-1")
	testing.expect_value(t, out[1].line, "retain\ttag/eDP-1/3\tstate=focused,occupied")

	// a line the adapter does not understand produces nothing
	testing.expect_value(t, len(kippsrv.vm_feed(v, a, "some other format")), 0)
}

@(test)
a_missing_adapter_fails_without_dying :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	_, ok := kippsrv.vm_load(v, "sources.d/wm-nothing-here.lua")
	testing.expect(t, !ok, "a missing file must fail, not crash")
}

// A script that never returns must not wedge the daemon. The sandbox keeps a
// descriptor out of a script, which is a different thing entirely.
@(test)
a_runaway_script_is_stopped :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	a, ok := kippsrv.vm_load(v, "tests/lua/runaway.lua")
	if !testing.expect(t, ok, "vm_load") do return
	defer kippsrv.vm_unload(v, a)

	out := kippsrv.vm_feed(v, a, "anything")     // returns rather than hanging
	testing.expect_value(t, len(out), 0)

	// and the VM still works afterwards
	testing.expect(t, kippsrv.vm_eval(v, `k.publish("after")`))
	testing.expect_value(t, len(v.emitted), 1)
}

// The step hook does not stop one greedy C call. `string.rep("x", 1e9)` is a
// single instruction to the VM, so the allocator cap is what stops it.
@(test)
a_greedy_script_is_stopped :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	before := v.mem.used
	testing.expect(t, !kippsrv.vm_eval(v, `local s = string.rep("x", 400000000)`),
	               "an allocation past the cap must fail the call")
	testing.expect(t, v.mem.used < kippsrv.MEM_CAP, "the cap held")

	// and the VM still works afterwards
	testing.expect(t, kippsrv.vm_eval(v, `k.publish("after")`))
	testing.expect_value(t, len(v.emitted), 1)
	testing.expect(t, v.mem.used < before + (1 << 20), "the memory came back")
}

// A field with no '=' is not kipp, and a writer must refuse it. Only the first
// '=' separates, so a value may hold more.
@(test)
a_field_with_no_equals_is_refused :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	testing.expect(t, kippsrv.vm_eval(v, `k.retain("net/uuid-1", "home")`))
	testing.expect_value(t, len(v.emitted), 0)

	testing.expect(t, kippsrv.vm_eval(v, `k.retain("net/uuid-1", "name=home=wifi")`))
	testing.expect_value(t, len(v.emitted), 1)
	if len(v.emitted) == 1 {
		m, ok := kippsrv.parse(v.emitted[0].line, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, m.topic, "net/uuid-1")
		testing.expect_value(t, m.payload["name"], "home=wifi")
	}
}

// A program that prints kipp needs no feed. Its retain and publish lines pass
// through, and the rest of its session does not.
@(test)
a_file_with_no_feed_passes_kipp_through :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	a, ok := kippsrv.vm_load(v, "sources.d/wm-hedl.lua")
	if !testing.expect(t, ok, "vm_load") do return

	retain := kippsrv.vm_feed(v, a, "retain\twin/7\tws=1\ttitle=a=b")
	testing.expect_value(t, len(retain), 1)
	testing.expect_value(t, retain[0].line, "retain\twin/7\tws=1\ttitle=a=b")

	publish := kippsrv.vm_feed(v, a, "publish\twm_done\tref=p17")
	testing.expect_value(t, len(publish), 1)
	testing.expect_value(t, publish[0].line, "publish\twm_done\tref=p17")

	testing.expect_value(t, len(kippsrv.vm_feed(v, a, "sync\tstate")), 0)
	testing.expect_value(t, len(kippsrv.vm_feed(v, a, "retain\twin/7\tbare")), 0)
}

// Only kipp reaches the socket.
@(test)
a_bad_topic_or_key_is_refused :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	testing.expect(t, kippsrv.vm_eval(v, `k.retain("Win/7")`))
	testing.expect(t, kippsrv.vm_eval(v, `k.retain("42/7")`))
	testing.expect(t, kippsrv.vm_eval(v, `k.retain("tag/*")`))
	testing.expect(t, kippsrv.vm_eval(v, `k.publish("key/super+a", "Bad Key=1")`))
	testing.expect_value(t, len(v.emitted), 0)
}
