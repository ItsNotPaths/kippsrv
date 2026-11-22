// Real output from real programs, converted by real adapters.
//
// The claim under test is that one adapter file absorbs a foreign format and
// nothing downstream learns it. These fixtures were captured on a live
// machine, commas, spaces, escapes and all.
package tests

import "core:fmt"
import "core:c"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import kippsrv "../src"

// Feed several fixtures to one adapter instance, flushing between each, the
// way two sources sharing one adapter behave.
@(private = "file")
run_many :: proc(v: ^kippsrv.Vm, adapter: string, fixtures: []string) -> ([]string, bool) {
	a, ok := kippsrv.vm_load(v, adapter)
	if !ok do return nil, false
	defer kippsrv.vm_unload(v, a)

	out := make([dynamic]string, context.temp_allocator)
	for fixture in fixtures {
		src, rerr := os.read_entire_file(fixture, context.temp_allocator)
		if rerr != nil do return nil, false
		text := string(src)
		for line in strings.split_lines_iterator(&text) {
			if line == "" do continue
			for l in kippsrv.vm_feed(v, a, line) do append(&out, strings.clone(l.line, context.temp_allocator))
		}
		for l in kippsrv.vm_flush(v, a) do append(&out, strings.clone(l.line, context.temp_allocator))
	}
	return out[:], true
}

@(private = "file")
kind_of :: proc(topic: string) -> string {
	kind, _, _ := strings.partition(topic, "/")
	return kind
}

@(private = "file")
run_fixture :: proc(v: ^kippsrv.Vm, adapter, fixture: string) -> ([]string, bool) {
	a, ok := kippsrv.vm_load(v, adapter)
	if !ok do return nil, false
	defer kippsrv.vm_unload(v, a)

	src, rerr := os.read_entire_file(fixture, context.temp_allocator)
	if rerr != nil do return nil, false

	out := make([dynamic]string, context.temp_allocator)
	text := string(src)
	for line in strings.split_lines_iterator(&text) {
		if line == "" do continue
		for l in kippsrv.vm_feed(v, a, line) do append(&out, strings.clone(l.line, context.temp_allocator))
	}
	for l in kippsrv.vm_flush(v, a) do append(&out, strings.clone(l.line, context.temp_allocator))
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
		{"hyprland seed",    "sources.d/wm-hypr.lua",       "tests/fmt/hypr-monitors.json", 2},
		{"dwl printstatus",  "sources.d/wm-dwl.lua",        "tests/fmt/dwl.txt",            5},
		{"nmcli -t",         "sources.d/net-nm.lua",        "tests/fmt/nmcli-t.txt",        3},
		{"pactl short",      "sources.d/audio-pw.lua",        "tests/fmt/pactl-short.txt",    2},
		{"brightnessctl -m", "sources.d/backlight-brightnessctl.lua", "tests/fmt/brightnessctl.txt",  1},
	}

	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

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
			m, good := kippsrv.parse(line, context.temp_allocator)
			testing.expectf(t, good, "%s: unparsable output %q", c.name, line)
			testing.expectf(t, kippsrv.is_topic(m.topic),
			                "%s: %q is not a topic", c.name, m.topic)
		}
	}
}

// A multi-line record needs state across feeds and an end-of-batch call.
// Neither existed before this test asked for them.
@(test)
a_multi_line_record_needs_flush :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	// feed only, no flush: the record has no terminator on its last line
	feed_only, ok := kippsrv.vm_load(v, "sources.d/power-upower.lua")
	if !testing.expect(t, ok) do return
	{
		src, _ := os.read_entire_file("tests/fmt/upower.txt", context.temp_allocator)
		text := string(src)
		n := 0
		for line in strings.split_lines_iterator(&text) {
			if line == "" do continue
			n += len(kippsrv.vm_feed(v, feed_only, line))
		}
		fmt.printfln("\n--- upower, feed only -> %d lines", n)
		testing.expect_value(t, n, 0)
	}
	kippsrv.vm_unload(v, feed_only)

	a, _ := kippsrv.vm_load(v, "sources.d/power-upower.lua")
	defer kippsrv.vm_unload(v, a)
	src, _ := os.read_entire_file("tests/fmt/upower.txt", context.temp_allocator)
	text := string(src)

	// Drain every call. The slice a call returns is only valid until the next
	// one, because the next one clears the buffer.
	done := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&text) {
		for l in kippsrv.vm_feed(v, a, line) do append(&done, strings.clone(l.line, context.temp_allocator))
	}
	for l in kippsrv.vm_flush(v, a) do append(&done, strings.clone(l.line, context.temp_allocator))
	fmt.printfln("--- upower, with flush -> %d lines", len(done))
	for l in done do fmt.printfln("    %s", l)
	testing.expect_value(t, len(done), 1)
	if len(done) == 0 do return

	m, good := kippsrv.parse(done[0], context.temp_allocator)
	testing.expect(t, good)
	testing.expect_value(t, kind_of(m.topic), "power")
	testing.expect_value(t, m.payload["state"], "fully-charged")
}

// upower --dump lists every device. DisplayDevice, upower's sum of the
// batteries, has no native-path, so its fields must not land on the device
// listed before it.
@(test)
upower_dump_keeps_devices_apart :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)
	a, _ := kippsrv.vm_load(v, "sources.d/power-upower.lua")
	defer kippsrv.vm_unload(v, a)
	src, _ := os.read_entire_file("tests/fmt/upower-dump.txt", context.temp_allocator)
	text := string(src)

	devices := make(map[string]kippsrv.Msg, allocator = context.temp_allocator)
	keep :: proc(devices: ^map[string]kippsrv.Msg, emits: []kippsrv.Emit) {
		for emit in emits {
			message, good := kippsrv.parse(strings.clone(emit.line, context.temp_allocator), context.temp_allocator)
			if good do devices[message.topic] = message
		}
	}
	for line in strings.split_lines_iterator(&text) do keep(&devices, kippsrv.vm_feed(v, a, line))
	keep(&devices, kippsrv.vm_flush(v, a))

	testing.expect_value(t, len(devices), 4)
	testing.expect_value(t, devices["power/BAT0"].payload["kind"], "battery")
	last_line_power := devices["power/ucsi-source-psy-USBC000:002"]
	testing.expect_value(t, last_line_power.payload["kind"], "line-power")
	testing.expect(t, "percentage" not_in last_line_power.payload, "DisplayDevice leaked into the device before it")
}

// JSON. Lua has no decoder, so k.json is the fourth call in the API. The
// adapter collects the blob in feed and decodes it in flush.
@(test)
json_converts_through_one_odin_call :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	a, ok := kippsrv.vm_load(v, "sources.d/wm-hypr.lua")
	if !testing.expect(t, ok) do return
	defer kippsrv.vm_unload(v, a)

	src, _ := os.read_entire_file("tests/fmt/hypr-monitors.json", context.temp_allocator)
	text := string(src)
	for line in strings.split_lines_iterator(&text) do kippsrv.vm_feed(v, a, line)

	out := kippsrv.vm_flush(v, a)
	fmt.printfln("\n--- hyprctl monitors -j -> %d lines", len(out))
	for l in out do fmt.printfln("    %s", l)

	testing.expect(t, len(out) >= 2, "a monitor and its focus")
	for e in out {
		m, good := kippsrv.parse(e.line, context.temp_allocator)
		testing.expectf(t, good, "unparsable output %q", e.line)
	}
}

// A user's adapter may invent a kind, and nothing in kippsrv is consulted. If
// this test ever fails, kipp has grown a schema.
@(test)
an_invented_kind_passes_through_untouched :: proc(t: ^testing.T) {
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	a, ok := kippsrv.vm_load(v, "tests/lua/invented.lua")
	if !testing.expect(t, ok) do return
	defer kippsrv.vm_unload(v, a)

	out := kippsrv.vm_feed(v, a, "anything")
	testing.expect_value(t, len(out), 1)
	if len(out) == 0 do return
	fmt.printfln("\n--- an unlisted kind -> %s", out[0])
	testing.expect_value(t, out[0].line, "retain\tsolar_panel/roof\twatts=412\ttilt=31")

	// and a consumer parses it with the same parser as every other line
	m, good := kippsrv.parse(out[0].line, context.temp_allocator)
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
	s, ok := kippsrv.serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return
	defer kippsrv.stop(s)

	fd := posix.socket(.UNIX, .STREAM)
	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)path)
	if !testing.expect(t, posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK) do return
	defer posix.close(fd)

	kippsrv.srv_ready(s, s.fd)          // accept
	kippsrv.srv_flush(s)                // greeting out of the way

	forged := "retain\ttag/eDP-1/9\tstate=focused\n"
	posix.send(fd, raw_data(forged), c.size_t(len(forged)), {})
	kippsrv.srv_ready(s, s.conns[0].fd)
	kippsrv.srv_flush(s)

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
	v, _ := kippsrv.vm_open()
	defer kippsrv.vm_close(v)

	out, ok := run_fixture(v, "sources.d/wm-hypr.lua", "tests/fmt/hypr-switch.txt")
	if !testing.expect(t, ok) do return

	// replay into a store, which is what a consumer effectively does
	st: kippsrv.Store
	defer kippsrv.store_close(&st)
	for line in out do kippsrv.store_apply(&st, kippsrv.Emit{line, 1})

	lines := make([dynamic]string, context.temp_allocator)
	kippsrv.store_each(&st, &lines)

	focused := 0
	for line in lines {
		m, good := kippsrv.parse(line, context.temp_allocator)
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
	s, ok := kippsrv.serve(path, "version\t2\tbroker=test")
	if !testing.expect(t, ok) do return
	defer kippsrv.stop(s)
	s.on_publish = kippsrv.deliver

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
	kippsrv.srv_ready(s, s.fd)
	first_end := s.conns[0].fd
	second := dial(path)
	defer posix.close(second)
	kippsrv.srv_ready(s, s.fd)
	second_end := s.conns[1].fd

	say(first, "connect\tbar\nwill\tpublish\tbye/bar\n")
	kippsrv.srv_ready(s, first_end)
	say(second, "connect\tbar\nsubscribe\tbye/*\n")
	kippsrv.srv_ready(s, second_end)
	kippsrv.srv_wills(s)
	kippsrv.srv_flush(s)

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
