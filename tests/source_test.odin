package tests

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import kippsrv "../src"
import "core:time"

// Drive a source set until every descriptor has ended, or the budget runs out.
@(private = "file")
drain :: proc(ss: ^kippsrv.Sources, budget := 200) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	fds: [16]posix.pollfd

	for _ in 0 ..< budget {
		n := kippsrv.src_fds(ss, fds[:])
		if n == 0 do break
		if posix.poll(&fds[0], posix.nfds_t(n), 50) <= 0 do continue
		for i in 0 ..< n {
			if fds[i].revents == {} do continue
			for l in kippsrv.src_ready(ss, fds[i].fd) {
				append(&out, strings.clone(l.line, context.temp_allocator))
			}
		}
	}
	return out[:]
}

// A blank line is skipped, not an empty unit that stops the source.
@(test)
exec_source_splits_lines :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, ok := kippsrv.vm_load(v, "tests/lua/wm-example.lua")
	if !testing.expect(t, ok) do return

	_, spawned := kippsrv.src_exec(&ss, "printf", `printf 'focus eDP-1 3\n\n\nfocus HDMI-A-1 9\n'`, a)
	if !testing.expect(t, spawned, "src_exec") do return

	out := drain(&ss)
	fmt.printfln("\n--- exec, lines -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 4)
}

// stdin is the way back: a line sent to an exec source reaches the child.
@(test)
a_line_sent_reaches_the_child :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, ok := kippsrv.vm_load(v, "tests/lua/wm-example.lua")
	if !testing.expect(t, ok) do return
	s, spawned := kippsrv.src_exec(&ss, "cat", "cat", a)
	if !testing.expect(t, spawned) do return

	testing.expect(t, kippsrv.src_send(s, transmute([]byte)string("focus eDP-1 5\n")))
	out := drain(&ss, 10)        // cat never ends, so a short budget
	testing.expect_value(t, len(out), 2)
}

// A command sh cannot find is a failed run, not a normal end, so its source
// goes offline. A command that runs and ends stays online.
@(test)
a_command_that_cannot_run_goes_offline :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, ok := kippsrv.vm_load(v, "tests/lua/wm-example.lua")
	if !testing.expect(t, ok) do return
	missing, _ := kippsrv.src_exec(&ss, "missing", "kippsrv-no-such-command", a)
	ran, _ := kippsrv.src_exec(&ss, "ran", "true", a)
	if !testing.expect(t, missing != nil && ran != nil) do return

	kippsrv.src_status(&ss)              // both start online
	drain(&ss)
	said := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< 100 {
		kippsrv.src_reap(&ss)
		for e in kippsrv.src_status(&ss) do append(&said, e.line)
		if len(said) > 0 do break
		time.sleep(10 * time.Millisecond)
	}
	time.sleep(50 * time.Millisecond)     // and `true` has ended too
	kippsrv.src_reap(&ss)
	for e in kippsrv.src_status(&ss) do append(&said, e.line)
	testing.expect_value(t, len(said), 1)
	if len(said) == 1 do testing.expect_value(t, said[0], "retain\tstatus/missing\tstate=offline")
}

// The last record of a multi-line format has no terminator. EOF is the
// terminator, and the source turns it into a flush.
@(test)
eof_flushes_the_last_record :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, ok := kippsrv.vm_load(v, "sources.d/power-upower.lua")
	if !testing.expect(t, ok) do return

	_, spawned := kippsrv.src_exec(&ss, "cat", "cat tests/fmt/upower.txt", a)
	if !testing.expect(t, spawned) do return

	out := drain(&ss)
	fmt.printfln("--- exec, EOF flush -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 1)
}

@(test)
timer_source_fires_on_its_period :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, _ := kippsrv.vm_load(v, "tests/lua/tick.lua")
	kippsrv.src_timer(&ss, "beat", 20, a)

	got := 0
	start := kippsrv.now_ms()
	for kippsrv.now_ms() - start < 120 {
		got += len(kippsrv.src_tick(&ss, kippsrv.now_ms()))
	}
	fmt.printfln("--- timer, 20ms over 120ms -> %d beats", got)
	testing.expect(t, got >= 4 && got <= 8, "roughly one beat per period")
}

// A poll that learns nothing is asked for less often. Anything new puts the
// source straight back to its configured rate.
@(test)
an_idle_source_backs_off :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, _ := kippsrv.vm_load(v, "tests/lua/wm-example.lua")
	s, ok := kippsrv.src_exec(&ss, "p", "true", a, 2000)
	if !testing.expect(t, ok) do return

	s.state = .Ended

	testing.expect_value(t, s.every, i64(2000))
	for _ in 0 ..< 3 do cycle(&ss, s, 0)        // three quiet cycles
	testing.expect_value(t, s.every, i64(4000))
	for _ in 0 ..< 3 do cycle(&ss, s, 0)
	testing.expect_value(t, s.every, i64(32000))

	cycle(&ss, s, 1)                            // something changed
	testing.expect_value(t, s.every, i64(2000))
	testing.expect_value(t, s.idle, 0)

	// a source told not to throttle is left alone
	s.thr = {}
	for _ in 0 ..< 6 do cycle(&ss, s, 0)
	testing.expect_value(t, s.every, i64(2000))
}

// One run of a source, and what the store made of it.
@(private = "file")
cycle :: proc(ss: ^kippsrv.Sources, s: ^kippsrv.Source, moved: int) {
	s.settled = false
	s.moved = moved
	kippsrv.src_settle(ss)
}

// A throttled source reaches its adapter once a window, and the newest unit
// it was given in between is not lost: it goes out when the window closes.
@(test)
a_throttled_source_holds_the_newest_unit :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)

	a, _ := kippsrv.vm_load(v, "tests/lua/wm-example.lua")
	s, ok := kippsrv.src_exec(&ss, "p", "true", a, 0)
	if !testing.expect(t, ok) do return
	s.thr.min_gap = 10_000

	out := make([dynamic]kippsrv.Emit, context.temp_allocator)
	kippsrv.src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 1"))
	testing.expect_value(t, len(out), 2)          // the first unit passes

	kippsrv.src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 2"))
	kippsrv.src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 3"))
	testing.expect_value(t, len(out), 2)          // both were held
	testing.expect_value(t, string(s.held[:]), "focus eDP-1 3")

	s.gap_due = 0                                 // the window closed
	held := kippsrv.src_tick(&ss, kippsrv.now_ms())
	testing.expect_value(t, len(held), 2)
	testing.expect_value(t, held[1].line, "retain\ttag/eDP-1/3\tstate=focused,occupied")
	testing.expect_value(t, len(s.held), 0)
}

// A connected socket is not due for anything. Counting its redial period gave
// poll a zero timeout, and the loop spun at one whole core.
@(test)
a_running_source_has_no_deadline :: proc(t: ^testing.T) {
	ss: kippsrv.Sources
	defer delete(ss.list)

	live := kippsrv.Source{kind = .Sock, every = kippsrv.RETRY_MS, base = kippsrv.RETRY_MS}
	append(&ss.list, &live)
	testing.expect_value(t, kippsrv.src_timeout(&ss, kippsrv.now_ms()), -1)

	live.state = .Ended
	live.due = kippsrv.now_ms() + 1000
	testing.expect(t, kippsrv.src_timeout(&ss, kippsrv.now_ms()) > 0, "a closed socket is due again")

	// A held unit is a deadline of its own, or poll would sleep through it.
	held := kippsrv.Source{kind = .Sock, gap_due = kippsrv.now_ms() + 20}
	append(&held.held, 'x')
	defer delete(held.held)
	append(&ss.list, &held)
	gap := kippsrv.src_timeout(&ss, kippsrv.now_ms())
	testing.expect(t, gap >= 0 && gap <= 20, "a held unit is due")
}

// A source that cannot be reached says so once on status/<name>, so a reader
// knows its facts are last-known, and says online again when it comes back.
@(test)
a_lost_source_goes_offline :: proc(t: ^testing.T) {
	path := "/tmp/kippsrv-lost.sock"
	srv, ok := kippsrv.serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return

	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	ss := kippsrv.Sources{vm = v}
	defer kippsrv.src_close(&ss)
	_, dialled := kippsrv.src_sock(&ss, "lost", path, kippsrv.NO_ADAPTER)
	if !testing.expect(t, dialled) do return

	status :: proc(ss: ^kippsrv.Sources) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for e in kippsrv.src_status(ss) do append(&out, e.line)
		return out[:]
	}
	first := status(&ss)
	testing.expect_value(t, len(first), 1)
	if len(first) == 1 do testing.expect_value(t, first[0], "retain\tstatus/lost\tstate=online")
	testing.expect_value(t, len(status(&ss)), 0)

	kippsrv.stop(srv)
	drain(&ss)
	later := kippsrv.now_ms()
	for _ in 0 ..< 3 {
		later += 1_000_000
		kippsrv.src_tick(&ss, later)          // each redial finds nothing
	}
	gone := status(&ss)
	testing.expect_value(t, len(gone), 1)
	if len(gone) == 1 do testing.expect_value(t, gone[0], "retain\tstatus/lost\tstate=offline")
	testing.expect_value(t, len(status(&ss)), 0)

	back, _ := kippsrv.serve(path, "version\t2\tbroker=test")
	defer kippsrv.stop(back)
	kippsrv.src_tick(&ss, later + 1_000_000)
	again := status(&ss)
	testing.expect_value(t, len(again), 1)
	if len(again) == 1 do testing.expect_value(t, again[0], "retain\tstatus/lost\tstate=online")
}
