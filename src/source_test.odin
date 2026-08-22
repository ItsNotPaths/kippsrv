package kippsrv

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"

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
				append(&out, strings.clone(l, context.temp_allocator))
			}
		}
	}
	return out[:]
}

@(test)
exec_source_splits_lines :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "lua/wm/example.lua")
	if !testing.expect(t, ok) do return

	_, spawned := src_exec(&ss, "printf",
	                       {"printf", "focus eDP-1 3\nfocus HDMI-A-1 9\n"}, a)
	if !testing.expect(t, spawned, "src_exec") do return

	out := drain(&ss)
	fmt.printfln("\n--- exec, lines -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 4)
}

// The last record of a multi-line format has no terminator. EOF is the
// terminator, and the source turns it into a flush.
@(test)
eof_flushes_the_last_record :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "lua/power/upower.lua")
	if !testing.expect(t, ok) do return

	_, spawned := src_exec(&ss, "cat", {"cat", "test/fmt/upower.txt"}, a)
	if !testing.expect(t, spawned) do return

	out := drain(&ss)
	fmt.printfln("--- exec, EOF flush -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 1)
}

@(test)
prefix_framing_cuts_whole_frames :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, ok := vm_load(v, "lua/wm/i3.lua")
	if !testing.expect(t, ok) do return

	// i3 and sway: six bytes of magic, a 32-bit length, a 32-bit type.
	_, spawned := src_exec(&ss, "cat", {"cat", "test/fmt/i3-frames.bin"}, a,
	                       Prefix{header = 14, at = 6, width = 4, le = true})
	if !testing.expect(t, spawned) do return

	out := drain(&ss)
	fmt.printfln("--- exec, length prefixed -> %d", len(out))
	for l in out do fmt.printfln("    %s", l)
	testing.expect_value(t, len(out), 2)
}

@(test)
raw_framing_hands_over_the_chunk :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)
	ss := Sources{vm = v}
	defer src_close(&ss)

	a, _ := vm_load(v, "test/lua/raw.lua")
	_, spawned := src_exec(&ss, "printf", {"printf", "no newline here"}, a, Raw{})
	if !testing.expect(t, spawned) do return

	out := drain(&ss)
	fmt.printfln("--- exec, raw -> %v", out)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 do testing.expect_value(t, out[0], "chunk\tbytes=15")
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
