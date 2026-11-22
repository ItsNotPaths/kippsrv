package kippsrv

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// Drive a source set until every descriptor has ended, or the budget runs out.
@(private = "file")
drain :: proc(ss: ^Sources, budget := 200) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	fds: [16]posix.pollfd

	for _ in 0 ..< budget {
		n := src_fds(ss, fds[:])
		if n == 0 do break
		if posix.poll(&fds[0], posix.nfds_t(n), 50) <= 0 do continue
		for i in 0 ..< n {
			if fds[i].revents == {} do continue
			for l in src_ready(ss, fds[i].fd) {
				append(&out, strings.clone(l.line, context.temp_allocator))
			}
		}
	}
	return out[:]
}

// A blank line is skipped, not an empty unit that stops the source.
@(test)
exec_source_splits_lines :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "sources.d/wm-example.lua")
	if !testing.expect(t, ok) do return

	_, spawned := src_exec(&ss, "printf", `printf 'focus eDP-1 3\n\n\nfocus HDMI-A-1 9\n'`, a)
	if !testing.expect(t, spawned, "src_exec") do return

	out := drain(&ss)
	fmt.printfln("\n--- exec, lines -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 4)
	testing.expect(t, !ss.list[0].dead, "a blank line must not stop the source")
}

// stdin is the way back: a line sent to an exec source reaches the child.
@(test)
a_line_sent_reaches_the_child :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "sources.d/wm-example.lua")
	if !testing.expect(t, ok) do return
	s, spawned := src_exec(&ss, "cat", "cat", a)
	if !testing.expect(t, spawned) do return

	testing.expect(t, src_send(s, transmute([]byte)string("focus eDP-1 5\n")))
	out := drain(&ss, 10)        // cat never ends, so a short budget
	testing.expect_value(t, len(out), 2)
}

// A command sh cannot find is a failed run, not a normal end, so its source
// goes offline. A command that runs and ends stays online.
@(test)
a_command_that_cannot_run_goes_offline :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "sources.d/wm-example.lua")
	if !testing.expect(t, ok) do return
	missing, _ := src_exec(&ss, "missing", "kippsrv-no-such-command", a)
	ran, _ := src_exec(&ss, "ran", "true", a)
	if !testing.expect(t, missing != nil && ran != nil) do return

	drain(&ss)
	for _ in 0 ..< 100 {
		src_reap(&ss)
		if missing.pid == 0 && ran.pid == 0 do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, missing.dead, "a command sh cannot find is offline")
	testing.expect(t, !ran.dead, "a command that ran is not")
}

// The last record of a multi-line format has no terminator. EOF is the
// terminator, and the source turns it into a flush.
@(test)
eof_flushes_the_last_record :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "sources.d/power-upower.lua")
	if !testing.expect(t, ok) do return

	_, spawned := src_exec(&ss, "cat", "cat test/fmt/upower.txt", a)
	if !testing.expect(t, spawned) do return

	out := drain(&ss)
	fmt.printfln("--- exec, EOF flush -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 1)
}

@(test)
timer_source_fires_on_its_period :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, _ := vm_load(v, "test/lua/tick.lua")
	src_timer(&ss, "beat", 20, a)

	got := 0
	start := now_ms()
	for now_ms() - start < 120 {
		got += len(src_tick(&ss, now_ms()))
	}
	fmt.printfln("--- timer, 20ms over 120ms -> %d beats", got)
	testing.expect(t, got >= 4 && got <= 8, "roughly one beat per period")
}

// A poll that learns nothing is asked for less often. Anything new puts the
// source straight back to its configured rate.
@(test)
an_idle_source_backs_off :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, _ := vm_load(v, "sources.d/wm-example.lua")
	s, ok := src_exec(&ss, "p", "true", a, 2000)
	if !testing.expect(t, ok) do return

	s.done = true

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
cycle :: proc(ss: ^Sources, s: ^Source, moved: int) {
	s.settled = false
	s.moved = moved
	src_settle(ss)
}

// A throttled source reaches its adapter once a window, and the newest unit
// it was given in between is not lost: it goes out when the window closes.
@(test)
a_throttled_source_holds_the_newest_unit :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, _ := vm_load(v, "sources.d/wm-example.lua")
	s, ok := src_exec(&ss, "p", "true", a, 0)
	if !testing.expect(t, ok) do return
	s.thr.min_gap = 10_000

	out := make([dynamic]Emit, context.temp_allocator)
	src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 1"))
	testing.expect_value(t, len(out), 2)          // the first unit passes

	src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 2"))
	src_feed(v, s, &out, transmute([]byte)string("focus eDP-1 3"))
	testing.expect_value(t, len(out), 2)          // both were held
	testing.expect_value(t, string(s.held[:]), "focus eDP-1 3")

	s.gap_due = 0                                 // the window closed
	held := src_tick(&ss, now_ms())
	testing.expect_value(t, len(held), 2)
	testing.expect_value(t, held[1].line, "retain\ttag/eDP-1/3\tstate=focused,occupied")
	testing.expect_value(t, len(s.held), 0)
}

// A connected socket is not due for anything. Counting its redial period gave
// poll a zero timeout, and the loop spun at one whole core.
@(test)
a_running_source_has_no_deadline :: proc(t: ^testing.T) {
	ss: Sources
	defer delete(ss.list)

	live := Source{kind = .Sock, every = RETRY_MS, base = RETRY_MS, done = false}
	append(&ss.list, &live)
	testing.expect_value(t, src_timeout(&ss, now_ms()), -1)

	live.done = true
	live.due = now_ms() + 1000
	testing.expect(t, src_timeout(&ss, now_ms()) > 0, "a closed socket is due again")

	// A held unit is a deadline of its own, or poll would sleep through it.
	held := Source{kind = .Sock, done = false, gap_due = now_ms() + 20}
	append(&held.held, 'x')
	defer delete(held.held)
	append(&ss.list, &held)
	gap := src_timeout(&ss, now_ms())
	testing.expect(t, gap >= 0 && gap <= 20, "a held unit is due")
}

// A source that cannot be reached says so once on status/<name>, so a reader
// knows its facts are last-known, and says online again when it comes back.
@(test)
a_lost_source_goes_offline :: proc(t: ^testing.T) {
	path := "/tmp/kippsrv-lost.sock"
	srv, ok := serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return

	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)
	_, dialled := src_sock(&ss, "lost", path, NO_ADAPTER)
	if !testing.expect(t, dialled) do return

	status :: proc(ss: ^Sources) -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for e in src_status(ss) do append(&out, e.line)
		return out[:]
	}
	first := status(&ss)
	testing.expect_value(t, len(first), 1)
	if len(first) == 1 do testing.expect_value(t, first[0], "retain\tstatus/lost\tstate=online")
	testing.expect_value(t, len(status(&ss)), 0)

	stop(srv)
	drain(&ss)
	later := now_ms()
	for _ in 0 ..< 3 {
		later += 1_000_000
		src_tick(&ss, later)          // each redial finds nothing
	}
	gone := status(&ss)
	testing.expect_value(t, len(gone), 1)
	if len(gone) == 1 do testing.expect_value(t, gone[0], "retain\tstatus/lost\tstate=offline")
	testing.expect_value(t, len(status(&ss)), 0)

	back, _ := serve(path, "version\t2\tbroker=test")
	defer stop(back)
	src_tick(&ss, later + 1_000_000)
	again := status(&ss)
	testing.expect_value(t, len(again), 1)
	if len(again) == 1 do testing.expect_value(t, again[0], "retain\tstatus/lost\tstate=online")
}
