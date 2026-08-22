package kippsrv

import "core:fmt"
import "core:c"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
rate :: proc(name: string, n: int, d: time.Duration) {
	per := f64(n) / time.duration_seconds(d)
	fmt.printfln("  %-28s %9.0f lines/s  (%.2f µs each)",
	             name, per, time.duration_microseconds(d) / f64(n))
}

@(test)
bench_layers :: proc(t: ^testing.T) {
	N :: 50_000
	line := "tag\teDP-1\t2\tstate=focused,occupied"

	fmt.println("\n--- one line through each layer")

	// 1. parse alone, no Lua
	{
		start := time.tick_now()
		for _ in 0 ..< N {
			parse(line, context.temp_allocator)
			free_all(context.temp_allocator)
		}
		rate("parse (Odin)", N, time.tick_since(start))
	}

	// 2. build alone
	{
		start := time.tick_now()
		for _ in 0 ..< N {
			o: Out
			begin(&o, "tag")
			add(&o, "eDP-1"); add(&o, "2"); add(&o, "state=focused,occupied")
			str(&o)
			free_all(context.temp_allocator)
		}
		rate("build (Odin)", N, time.tick_since(start))
	}

	// 3. a full Lua round trip: one line in, two facts out
	{
		v, _ := vm_open()
		defer vm_close(v)
		a, ok := vm_load(v, "lua/wm/example.lua")
		if !testing.expect(t, ok) do return

		start := time.tick_now()
		for _ in 0 ..< N {
			vm_feed(v, a, "focus eDP-1 3")
			free_all(context.temp_allocator)
		}
		rate("adapter feed (Lua)", N, time.tick_since(start))
	}

	// 4. the heaviest real adapter: JSON decode plus emits
	{
		v, _ := vm_open()
		defer vm_close(v)
		a, _ := vm_load(v, "lua/wm/hypr.lua")

		start := time.tick_now()
		for _ in 0 ..< N {
			vm_feed(v, a, "openwindow>>56503fc49590,3,firefox,Some Page Title")
			free_all(context.temp_allocator)
		}
		rate("hypr adapter (Lua)", N, time.tick_since(start))
	}
}

// Broadcast cost against the number of connected consumers, and the point at
// which a consumer that stops reading is dropped.
@(test)
bench_broadcast :: proc(t: ^testing.T) {
	N :: 20_000
	line := "tag\teDP-1\t2\tstate=focused,occupied"

	dial :: proc(path: string) -> posix.FD {
		addr: posix.sockaddr_un
		addr.sun_family = .UNIX
		copy(addr.sun_path[:], transmute([]c.char)path)
		fd := posix.socket(.UNIX, .STREAM)
		if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
			posix.close(fd)
			return -1
		}
		return fd
	}

	fmt.println("--- broadcast, consumers that never read")
	for consumers in ([]int{0, 1, 4, 16}) {
		path := fmt.tprintf("/tmp/kbench-%d.sock", consumers)
		s, ok := serve(path, "version\t1\tbench\tproto=1")
		if !testing.expect(t, ok) do continue
		defer stop(s)

		fds := make([dynamic]posix.FD, context.temp_allocator)
		for _ in 0 ..< consumers {
			fd := dial(path)
			if fd < 0 do break
			append(&fds, fd)
			srv_ready(s, s.fd)          // accept it
		}
		defer for fd in fds do posix.close(fd)

		start := time.tick_now()
		sent := 0
		for _ in 0 ..< N {
			broadcast(s, line)
			sent += 1
			if sent % 32 == 0 do srv_flush(s)   // one pass, one write
			if consumers > 0 && len(s.conns) == 0 do break
		}
		srv_flush(s)
		d := time.tick_since(start)

		fmt.printfln("  %2d consumers  %10.0f lines/s   %d sent, %d still connected",
		             consumers, f64(sent) / time.duration_seconds(d),
		             sent, len(s.conns))
	}
}
