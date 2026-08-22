// Real output from real programs, converted by real adapters.
//
// The claim under test is that one adapter file absorbs a foreign format and
// nothing downstream learns it. These fixtures were captured on a live
// machine, commas, spaces, escapes and all.
package kippsrv

import "core:fmt"
import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// Feed several fixtures to one adapter instance, flushing between each, the
// way two sources sharing one adapter behave.
@(private = "file")
run_many :: proc(v: ^Vm, adapter: string, fixtures: []string) -> ([]string, bool) {
	a, ok := vm_load(v, adapter)
	if !ok do return nil, false
	defer vm_unload(v, a)

	out := make([dynamic]string, context.temp_allocator)
	for fixture in fixtures {
		src, rerr := os.read_entire_file(fixture, context.temp_allocator)
		if rerr != nil do return nil, false
		text := string(src)
		for line in strings.split_lines_iterator(&text) {
			if line == "" do continue
			for l in vm_feed(v, a, line) do append(&out, strings.clone(l.line, context.temp_allocator))
		}
		for l in vm_flush(v, a) do append(&out, strings.clone(l.line, context.temp_allocator))
	}
	return out[:], true
}

@(private = "file")
run_fixture :: proc(v: ^Vm, adapter, fixture: string) -> ([]string, bool) {
	a, ok := vm_load(v, adapter)
	if !ok do return nil, false
	defer vm_unload(v, a)

	src, rerr := os.read_entire_file(fixture, context.temp_allocator)
	if rerr != nil do return nil, false

	out := make([dynamic]string, context.temp_allocator)
	text := string(src)
	for line in strings.split_lines_iterator(&text) {
		if line == "" do continue
		for l in vm_feed(v, a, line) do append(&out, strings.clone(l.line, context.temp_allocator))
	}
	for l in vm_flush(v, a) do append(&out, strings.clone(l.line, context.temp_allocator))
	return out[:], true
}

@(test)
adapters_convert_real_formats :: proc(t: ^testing.T) {
	Case :: struct {
		name, adapter, fixture: string,
		least:                  int,
	}
	cases := []Case{
		// The seed first. An event stream says what changed, not what is,
		// so without it the adapter cannot attribute an event to a monitor.
		{"hyprland seed",    "lua/wm/hypr.lua",       "test/fmt/hypr-monitors.json", 2},
		{"dwl printstatus",  "lua/wm/dwl.lua",        "test/fmt/dwl.txt",            5},
		{"nmcli -t",         "lua/net/nm.lua",        "test/fmt/nmcli-t.txt",        3},
		{"pactl short",      "lua/audio/pw.lua",        "test/fmt/pactl-short.txt",    2},
		{"brightnessctl -m", "lua/backlight/brightnessctl.lua", "test/fmt/brightnessctl.txt",  1},
	}

	v, _ := vm_open()
	defer vm_close(v)

	for c in cases {
		out, ok := run_fixture(v, c.adapter, c.fixture)
		if !testing.expectf(t, ok, "%s: could not run", c.name) do continue

		fmt.printfln("\n--- %s -> %d lines", c.name, len(out))
		for l in out do fmt.printfln("    %s", l)

		testing.expectf(t, len(out) >= c.least,
		                "%s produced %d lines, wanted at least %d",
		                c.name, len(out), c.least)

		// Whatever the source did, what comes out is kipp.
		for line in out {
			m, good := parse(line, context.temp_allocator)
			testing.expectf(t, good, "%s: unparsable output %q", c.name, line)
			testing.expectf(t, !strings.contains(m.kind, " "),
			                "%s: kind %q holds a space", c.name, m.kind)
		}
	}
}

// A multi-line record needs state across feeds and an end-of-batch call.
// Neither existed before this test asked for them.
@(test)
a_multi_line_record_needs_flush :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	// feed only, no flush: the record has no terminator on its last line
	feed_only, ok := vm_load(v, "lua/power/upower.lua")
	if !testing.expect(t, ok) do return
	{
		src, _ := os.read_entire_file("test/fmt/upower.txt", context.temp_allocator)
		text := string(src)
		n := 0
		for line in strings.split_lines_iterator(&text) {
			if line == "" do continue
			n += len(vm_feed(v, feed_only, line))
		}
		fmt.printfln("\n--- upower, feed only -> %d lines", n)
		testing.expect_value(t, n, 0)
	}
	vm_unload(v, feed_only)

	a, _ := vm_load(v, "lua/power/upower.lua")
	defer vm_unload(v, a)
	src, _ := os.read_entire_file("test/fmt/upower.txt", context.temp_allocator)
	text := string(src)

	// Drain every call. The slice a call returns is only valid until the next
	// one, because the next one clears the buffer.
	done := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		for l in vm_feed(v, a, line) do append(&done, strings.clone(l.line, context.temp_allocator))
	}
	for l in vm_flush(v, a) do append(&done, strings.clone(l.line, context.temp_allocator))
	fmt.printfln("--- upower, with flush -> %d lines", len(done))
	for l in done do fmt.printfln("    %s", l)
	testing.expect_value(t, len(done), 1)
	if len(done) == 0 do return

	m, good := parse(done[0], context.temp_allocator)
	testing.expect(t, good)
	testing.expect_value(t, m.kind, "power")
	testing.expect_value(t, m.attr["state"], "fully-charged")
}

// JSON. Lua has no decoder, so k.json is the fourth call in the API. The
// adapter collects the blob in feed and decodes it in flush.
@(test)
json_converts_through_one_odin_call :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "lua/wm/hypr.lua")
	if !testing.expect(t, ok) do return
	defer vm_unload(v, a)

	src, _ := os.read_entire_file("test/fmt/hypr-monitors.json", context.temp_allocator)
	text := string(src)
	for line in strings.split_lines_iterator(&text) do vm_feed(v, a, line)

	out := vm_flush(v, a)
	fmt.printfln("\n--- hyprctl monitors -j -> %d lines", len(out))
	for l in out do fmt.printfln("    %s", l)

	testing.expect(t, len(out) >= 2, "a monitor and its focus")
	for e in out {
		m, good := parse(e.line, context.temp_allocator)
		testing.expectf(t, good, "unparsable output %q", e.line)
	}
}

// Binary framing. Lua strings are 8-bit clean and string.unpack is in the
// string library, so the adapter reads the frame itself. Odin hands over the
// bytes and never learns the magic string.
//
// The frames here are synthesized. No i3 or sway is installed on this
// machine, so this proves the mechanism and not compatibility.
@(test)
a_binary_frame_is_read_in_lua :: proc(t: ^testing.T) {
	frame :: proc(kind: u32, body: string) -> []byte {
		out := make([dynamic]byte, context.temp_allocator)
		append(&out, "i3-ipc")
		for shift in ([]uint{0, 8, 16, 24}) do append(&out, byte(u32(len(body)) >> shift))
		for shift in ([]uint{0, 8, 16, 24}) do append(&out, byte(kind >> shift))
		append(&out, body)
		return out[:]
	}

	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "lua/wm/i3.lua")
	if !testing.expect(t, ok) do return
	defer vm_unload(v, a)

	ws := `[{"num":1,"name":"one","output":"eDP-1","focused":true},
	        {"num":2,"name":"two","output":"HDMI-A-1","focused":false}]`
	out := vm_feed_bytes(v, a, frame(1, ws))

	fmt.printfln("\n--- i3-shaped binary frame -> %d lines", len(out))
	for l in out do fmt.printfln("    %s", l)

	testing.expect_value(t, len(out), 3)
	if len(out) < 3 do return
	testing.expect_value(t, out[0].line, "tag\teDP-1\t1\tstate=focused,occupied")
	testing.expect_value(t, out[1].line, "focus\teDP-1")
}

// Every window manager adapter must speak the same vocabulary, or the bar
// needs one file per window manager and the whole hop bought nothing.
// Nothing in the code enforces this, so a test does.
@(test)
wm_adapters_share_one_vocabulary :: proc(t: ^testing.T) {
	allowed := make(map[string]bool, allocator = context.temp_allocator)
	{
		src, _ := os.read_entire_file("vocab/wm.txt", context.temp_allocator)
		text := string(src)
		for line in strings.split_lines_iterator(&text) {
			word := strings.trim_space(line)
			if word == "" || strings.has_prefix(word, "#") do continue
			if i := strings.index_byte(word, '#'); i >= 0 {
				word = strings.trim_space(word[:i])
			}
			allowed[word] = true
		}
	}
	testing.expect(t, len(allowed) > 0, "vocab/wm.txt is empty")

	v, _ := vm_open()
	defer vm_close(v)

	seen := make(map[string]int, allocator = context.temp_allocator)

	Seeded :: struct{name, adapter: string, fixtures: []string}
	for c in ([]Seeded{
		// One adapter, two sources: the seed and then the stream.
		{"hypr", "lua/wm/hypr.lua", {"test/fmt/hypr-monitors.json",
		                             "test/fmt/hypr-socket2.txt"}},
		{"dwl",  "lua/wm/dwl.lua",  {"test/fmt/dwl.txt"}},
	}) {
		out, ok := run_many(v, c.adapter, c.fixtures)
		if !testing.expectf(t, ok, "%s: could not run", c.name) do continue

		kinds := make(map[string]bool, allocator = context.temp_allocator)
		for line in out {
			m, good := parse(line, context.temp_allocator)
			if !good do continue
			kinds[strings.clone(m.kind, context.temp_allocator)] = true
		}

		list := make([dynamic]string, context.temp_allocator)
		for kind in kinds do append(&list, kind)
		fmt.printfln("\n--- %s emits %v", c.name, list[:])

		for kind in kinds {
			testing.expectf(t, allowed[kind],
			                "%s emits %q, which is not in vocab/wm.txt",
			                c.name, kind)
			seen[kind] = seen[kind] + 1
		}
	}

	// They have to actually overlap, or "one vocabulary" is a word.
	shared := 0
	for _, n in seen do if n > 1 do shared += 1
	fmt.printfln("--- %d kinds emitted by both", shared)
	testing.expect(t, shared >= 3, "the two adapters barely overlap")
}

// A user's adapter may invent a kind, and nothing in kippsrv is consulted. The
// vocabulary files are a lint over the adapters this repo ships, not a gate at
// runtime. If this test ever fails, kipp has grown a schema.
@(test)
an_invented_kind_passes_through_untouched :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "test/lua/invented.lua")
	if !testing.expect(t, ok) do return
	defer vm_unload(v, a)

	out := vm_feed(v, a, "anything")
	testing.expect_value(t, len(out), 1)
	if len(out) == 0 do return
	fmt.printfln("\n--- an unlisted kind -> %s", out[0])
	testing.expect_value(t, out[0].line, "solar_panel\troof\twatts=412\ttilt=31")

	// and a consumer parses it with the same parser as every other line
	m, good := parse(out[0].line, context.temp_allocator)
	testing.expect(t, good)
	testing.expect_value(t, m.kind, "solar_panel")
	testing.expect_value(t, m.attr["watts"], "412")
}

// A consumer sends commands and may not send facts. If this ever passes a
// lowercase kind through, anything that can connect can forge desktop state
// for everything else that reads.
@(test)
a_consumer_cannot_forge_a_fact :: proc(t: ^testing.T) {
	// The rule lives in read_conn, so it is exercised over a real socket.
	path := "/tmp/kippsrv-forge.sock"
	s, ok := serve(path, "version\t1\ttest\tproto=1")
	if !testing.expect(t, ok) do return
	defer stop(s)

	fd := posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)path)
	if !testing.expect(t, posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK) do return
	defer posix.close(fd)

	srv_ready(s, s.fd)          // accept
	srv_flush(s)                // greeting and sync out of the way

	forged := "tag\teDP-1\t9\tstate=focused\n"
	posix.send(fd, raw_data(forged), c.size_t(len(forged)), {})
	srv_ready(s, s.conns[0].fd)
	srv_flush(s)

	buf: [512]byte
	n := posix.recv(fd, raw_data(buf[:]), len(buf), {})
	got := string(buf[:max(0, int(n))])
	fmt.printfln("\n--- a forged fact gets: %s", strings.trim_space(got))
	testing.expect(t, strings.contains(got, "error\tbadcmd"),
	               "a lowercase kind from a consumer must be refused")
}
