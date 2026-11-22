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
kind_of :: proc(topic: string) -> string {
	kind, _, _ := strings.partition(topic, "/")
	return kind
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
		{"hyprland seed",    "sources.d/wm-hypr.lua",       "test/fmt/hypr-monitors.json", 2},
		{"dwl printstatus",  "sources.d/wm-dwl.lua",        "test/fmt/dwl.txt",            5},
		{"nmcli -t",         "sources.d/net-nm.lua",        "test/fmt/nmcli-t.txt",        3},
		{"pactl short",      "sources.d/audio-pw.lua",        "test/fmt/pactl-short.txt",    2},
		{"brightnessctl -m", "sources.d/backlight-brightnessctl.lua", "test/fmt/brightnessctl.txt",  1},
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
			testing.expectf(t, is_topic(m.topic),
			                "%s: %q is not a topic", c.name, m.topic)
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
	feed_only, ok := vm_load(v, "sources.d/power-upower.lua")
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

	a, _ := vm_load(v, "sources.d/power-upower.lua")
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
	testing.expect_value(t, kind_of(m.topic), "power")
	testing.expect_value(t, m.payload["state"], "fully-charged")
}

// JSON. Lua has no decoder, so k.json is the fourth call in the API. The
// adapter collects the blob in feed and decodes it in flush.
@(test)
json_converts_through_one_odin_call :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	a, ok := vm_load(v, "sources.d/wm-hypr.lua")
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
		{"hypr", "sources.d/wm-hypr.lua", {"test/fmt/hypr-monitors.json",
		                             "test/fmt/hypr-socket2.txt"}},
		{"dwl",  "sources.d/wm-dwl.lua",  {"test/fmt/dwl.txt"}},
	}) {
		out, ok := run_many(v, c.adapter, c.fixtures)
		if !testing.expectf(t, ok, "%s: could not run", c.name) do continue

		kinds := make(map[string]bool, allocator = context.temp_allocator)
		for line in out {
			m, good := parse(line, context.temp_allocator)
			if !good do continue
			kinds[strings.clone(kind_of(m.topic), context.temp_allocator)] = true
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
	testing.expect_value(t, out[0].line, "retain\tsolar_panel/roof\twatts=412\ttilt=31")

	// and a consumer parses it with the same parser as every other line
	m, good := parse(out[0].line, context.temp_allocator)
	testing.expect(t, good)
	testing.expect_value(t, kind_of(m.topic), "solar_panel")
	testing.expect_value(t, m.payload["watts"], "412")
}

// A client that has not connected may publish but not retain. If this ever
// passes, anything that can connect can forge desktop state for everything
// else that reads.
@(test)
a_consumer_cannot_forge_a_fact :: proc(t: ^testing.T) {
	// The rule lives in read_conn, so it is exercised over a real socket.
	path := "/tmp/kippsrv-forge.sock"
	s, ok := serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return
	defer stop(s)

	fd := posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)path)
	if !testing.expect(t, posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK) do return
	defer posix.close(fd)

	srv_ready(s, s.fd)          // accept
	srv_flush(s)                // greeting out of the way

	forged := "retain\ttag/eDP-1/9\tstate=focused\n"
	posix.send(fd, raw_data(forged), c.size_t(len(forged)), {})
	srv_ready(s, s.conns[0].fd)
	srv_flush(s)

	buf: [512]byte
	n := posix.recv(fd, raw_data(buf[:]), len(buf), {})
	got := string(buf[:max(0, int(n))])
	fmt.printfln("\n--- a forged fact gets: %s", strings.trim_space(got))
	testing.expect(t, strings.contains(got, "error\tnoconnect"),
	               "a retain before connect must be refused")
}

// Focus moves between tags. Saying which one is focused without saying which
// one no longer is leaves every tag ever visited focused, because each tag is
// its own fact keyed by kind and subject.
@(test)
switching_tags_clears_the_last_one :: proc(t: ^testing.T) {
	v, _ := vm_open()
	defer vm_close(v)

	out, ok := run_fixture(v, "sources.d/wm-hypr.lua", "test/fmt/hypr-switch.txt")
	if !testing.expect(t, ok) do return

	// replay into a store, which is what a consumer effectively does
	st: Store
	defer store_close(&st)
	for line in out do store_apply(&st, Emit{line, 1})

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)

	focused := 0
	for line in lines {
		m, good := parse(line, context.temp_allocator)
		if good && kind_of(m.topic) == "tag" && strings.contains(m.payload["state"], "focused") {
			focused += 1
		}
	}
	fmt.printfln("\n--- after 1 -> 2 -> 3, tags marked focused: %d", focused)
	for line in lines do fmt.printfln("    %s", line)
	testing.expect_value(t, focused, 1)
}

// A second client with the same name closes the first, as in MQTT, and the
// first one's will fires.
@(test)
a_second_connect_closes_the_first :: proc(t: ^testing.T) {
	path := "/tmp/kippsrv-twice.sock"
	s, ok := serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return
	defer stop(s)

	dial :: proc(path: string) -> posix.FD {
		addr: posix.sockaddr_un
		addr.sun_family = .UNIX
		copy(addr.sun_path[:], transmute([]c.char)path)
		fd := posix.socket(.UNIX, .STREAM)
		posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr))
		return fd
	}
	say :: proc(fd: posix.FD, text: string) {
		posix.send(fd, raw_data(text), c.size_t(len(text)), {})
	}

	first := dial(path)
	defer posix.close(first)
	srv_ready(s, s.fd)
	first_end := s.conns[0].fd
	second := dial(path)
	defer posix.close(second)
	srv_ready(s, s.fd)
	second_end := s.conns[1].fd

	say(first, "connect\tbar\nwill\tpublish\tbye/bar\n")
	srv_ready(s, first_end)
	say(second, "connect\tbar\nsubscribe\tbye/*\n")
	srv_ready(s, second_end)
	srv_wills(s)
	srv_flush(s)

	buf: [512]byte
	got := ""
	for {     // the greeting, then the end
		pfd := posix.pollfd{fd = first, events = {.IN}}
		if posix.poll(&pfd, 1, 500) <= 0 do break
		n := posix.recv(first, raw_data(buf[:]), len(buf), {})
		if n <= 0 {
			got = "closed"
			break
		}
	}
	testing.expect_value(t, got, "closed")

	n := posix.recv(second, raw_data(buf[:]), len(buf), {})
	heard := string(buf[:max(0, int(n))])
	testing.expect(t, strings.contains(heard, "publish\tbye/bar"), "the first one's will fires")
}
