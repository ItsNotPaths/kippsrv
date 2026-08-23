// Foreign sources. Four kinds, none of them a domain.
//
//   exec   spawn a command and read its output
//   sock   connect to a unix socket
//   timer  fire on a period
//   dbus   subscribe to a signal          (dbus.odin, not here)
//
// A source owns the descriptor and the framing, so an adapter gets whole
// units and never reassembles a torn one.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

// ---------------------------------------------------------------- framing

// Split on a newline. Nearly every text tool.
Lines :: struct {}

// A fixed header carrying the body length. i3 and sway are
// {header = 14, at = 6, width = 4, le = true}: six bytes of magic, then the
// length, then the message type.
Prefix :: struct {
	header: int,
	at:     int,
	width:  int,
	le:     bool,
}

// Hand over whatever arrived. For a source that frames itself.
Raw :: struct {}

Framing :: union #no_nil {
	Lines,
	Prefix,
	Raw,
}

Kind :: enum {
	Exec,
	Sock,
	Timer,
	Dbus,
}

Source :: struct {
	id:      int,
	name:    string,
	kind:    Kind,
	fd:      posix.FD,
	pid:     posix.pid_t,
	adapter: Adapter,
	framing: Framing,
	buf:     [dynamic]byte,
	argv:    []string,   // exec, kept so it can be run again
	path:    string,     // sock, kept so it can be dialled again
	base:    i64,        // the period the configuration asked for
	every:   i64,        // the period in use, which backoff can stretch
	idle:    int,        // polls in a row that changed nothing
	steady:  bool,       // backoff is off for this source
	due:     i64,        // next fire on the monotonic clock
	done:    bool,       // ended for now
	fails:   int,        // respawns in a row that did not start
	dead:    bool,       // gone for good. Its facts are stale
	reaped:  bool,       // the store has been told
	bus:     ^Bus,       // dbus only
}

Sources :: struct {
	vm:      ^Vm,
	list:    [dynamic]^Source,
	next_id: int,
	last:    ^Source,     // the source src_ready just handled
	warned:  bool,        // the poll set overflowed, reported once
}

MAX_BUF   :: 1 << 20   // a source that never frames must not grow without end
RETRY_MS  :: 2000      // how often a closed socket is dialled again

// A poll that learns nothing still costs a fork, an exec and a Lua call. The
// store spares the consumers, not the machine.
IDLE_BEFORE_BACKOFF :: 3
BACKOFF_MAX_FACTOR  :: 16
BACKOFF_CEILING_MS  :: 60_000

// ------------------------------------------------------------------ reaping

// A polling source forks once a period. Without this the process table fills
// and fork eventually fails for the whole session.
reap :: proc() {
	for {
		st: c.int
		if posix.waitpid(-1, &st, {.NOHANG}) <= 0 do return
	}
}

// ------------------------------------------------------------------ time

now_ms :: proc() -> i64 {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	return i64(ts.tv_sec) * 1000 + i64(ts.tv_nsec) / 1_000_000
}

// ----------------------------------------------------------------- start

@(private = "file")
set_flags :: proc(fd: posix.FD) {
	posix.fcntl(fd, .SETFL, posix.O_Flags{.NONBLOCK})
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
}

@(private = "file")
add :: proc(ss: ^Sources, s: ^Source) -> ^Source {
	s.buf = make([dynamic]byte)
	ss.next_id += 1
	s.id = ss.next_id
	append(&ss.list, s)
	return s
}

// Spawn a command and read its stdout.
// A command that ends and is run again on a period. `every` of 0 runs it once.
src_exec :: proc(ss: ^Sources, name: string, argv: []string, adapter: Adapter,
                 framing: Framing = Lines{}, every: i64 = 0) -> (^Source, bool) {
	// Built before the fork. Between fork and exec only async-signal-safe
	// calls are allowed, and an allocator whose lock another thread held at
	// fork time will never unlock in the child.
	cargv := make([]cstring, len(argv) + 1)
	defer delete(cargv)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a)
	defer for cs in cargv[:len(argv)] do delete(cs)
	cargv[len(argv)] = nil

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return nil, false

	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0]); posix.close(fds[1])
		return nil, false
	}
	if pid == 0 {
		posix.dup2(fds[1], posix.STDOUT_FILENO)
		posix.close(fds[0])
		posix.close(fds[1])
		posix.execvp(cargv[0], raw_data(cargv))
		posix._exit(127)
	}

	posix.close(fds[1])
	set_flags(fds[0])

	kept := make([]string, len(argv))
	for a, i in argv do kept[i] = strings.clone(a)


	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Exec, fd = fds[0], pid = pid,
		adapter = adapter, framing = framing, argv = kept, every = every, base = every,
	})), true
}

// Its adapter and its state survive, so a poll builds on the last run.
@(private = "file")
respawn :: proc(s: ^Source) -> bool {
	cargv := make([]cstring, len(s.argv) + 1)
	defer delete(cargv)
	for a, i in s.argv do cargv[i] = strings.clone_to_cstring(a)
	defer for cs in cargv[:len(s.argv)] do delete(cs)
	cargv[len(s.argv)] = nil

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return false

	pid := posix.fork()
	if pid < 0 {
		posix.close(fds[0]); posix.close(fds[1])
		return false
	}
	if pid == 0 {
		posix.dup2(fds[1], posix.STDOUT_FILENO)
		posix.close(fds[0])
		posix.close(fds[1])
		posix.execvp(cargv[0], raw_data(cargv))
		posix._exit(127)
	}
	posix.close(fds[1])
	set_flags(fds[0])
	s.fd = fds[0]
	s.pid = pid
	s.done = false
	clear(&s.buf)
	return true
}

// Connect to a unix socket and read it.
src_sock :: proc(ss: ^Sources, name, path: string,
                 adapter: Adapter, framing: Framing = Lines{}) -> (^Source, bool) {
	addr: posix.sockaddr_un
	if len(path) >= len(addr.sun_path) do return nil, false
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)path)

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return nil, false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return nil, false
	}
	set_flags(fd)
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Sock, fd = fd, path = strings.clone(path),
		adapter = adapter, framing = framing, every = RETRY_MS, base = RETRY_MS,
	})), true
}

// A compositor that restarts should not strand us with its old facts.
@(private = "file")
redial :: proc(s: ^Source) -> bool {
	addr: posix.sockaddr_un
	if len(s.path) >= len(addr.sun_path) do return false
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)s.path)

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return false
	}
	set_flags(fd)
	s.fd = fd
	s.done = false
	clear(&s.buf)
	return true
}

// A bus connection. dbus.odin makes the connection; this puts it in the list
// so it has an id and a lifecycle like everything else.
src_dbus :: proc(ss: ^Sources, name: string, bus: ^Bus, fd: posix.FD,
                 adapter: Adapter) -> ^Source {
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Dbus, fd = fd,
		adapter = adapter, bus = bus,
	}))
}

// Fire on a period. It carries no data, so the adapter's `tick` runs instead
// of `feed`.
src_timer :: proc(ss: ^Sources, name: string, every_ms: i64,
                  adapter: Adapter) -> (^Source, bool) {
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Timer, fd = -1,
		adapter = adapter, every = every_ms, base = every_ms, due = now_ms() + every_ms,
	})), true
}

src_close :: proc(ss: ^Sources) {
	for s in ss.list {
		if s.kind == .Dbus do dbus_close(s)
		if s.fd >= 0 do posix.close(s.fd)
		if s.pid > 0 do posix.kill(s.pid, .SIGTERM)
		for a in s.argv do delete(a)
		delete(s.argv)
		delete(s.path)
		delete(s.buf)
		delete(s.name)
		free(s)
	}
	delete(ss.list)
}

// -------------------------------------------------------------- deframing

// One whole unit, or nothing. The caller reads again and asks later.
@(private = "file")
take :: proc(s: ^Source) -> ([]byte, bool) {
	switch f in s.framing {
	case Lines:
		for b, i in s.buf {
			if b == '\n' {
				unit := s.buf[:i]
				return unit, true
			}
		}
		return nil, false

	case Prefix:
		// A zero unit would be consumed as zero bytes and asked for again
		// forever. config_load rejects the values that produce one, and this
		// is the second line of defence.
		if f.header <= 0 || f.width <= 0 || f.at + f.width > f.header {
			return nil, false
		}
		if len(s.buf) < f.header do return nil, false

		size := 0
		for i in 0 ..< f.width {
			shift := uint(8 * (i if f.le else f.width - 1 - i))
			size |= int(s.buf[f.at + i]) << shift
		}
		total := f.header + size
		if size < 0 || total > MAX_BUF do return nil, false
		if len(s.buf) < total do return nil, false
		return s.buf[:total], true

	case Raw:
		if len(s.buf) == 0 do return nil, false
		return s.buf[:], true
	}
	return nil, false
}

@(private = "file")
consumed :: proc(s: ^Source, unit: []byte) {
	n := len(unit)
	if _, is_lines := s.framing.(Lines); is_lines do n += 1   // the newline
	if n > len(s.buf) do n = len(s.buf)
	copy(s.buf[:], s.buf[n:])
	resize(&s.buf, len(s.buf) - n)
}

// ------------------------------------------------------------------ pump

src_fds :: proc(ss: ^Sources, dst: []posix.pollfd) -> int {
	n := 0
	dropped := 0
	for s in ss.list {
		if s.fd < 0 || s.done do continue
		if n == len(dst) {
			dropped += 1
			continue
		}
		dst[n] = {fd = s.fd, events = {.IN}}
		n += 1
	}
	// Silently not reading a source looks exactly like a source with nothing
	// to say.
	if dropped > 0 && !ss.warned {
		ss.warned = true
		fmt.eprintfln(
`kippsrv: %d sources beyond the poll set of %d are not being read, so whatever
         they report is missing. Remove sources from config.lua, or merge
         several polls into one command. [E-sources] See DIAGNOSTICS.md.`,
			dropped, len(dst))
	}
	return n
}

// The nearest timer, in ms, for the poll timeout. -1 when none is pending.
src_timeout :: proc(ss: ^Sources, now: i64) -> i32 {
	best: i64 = -1
	for s in ss.list {
		if s.every == 0 || s.dead do continue
		if s.kind == .Exec && !s.done do continue
		left := max(0, s.due - now)
		if best < 0 || left < best do best = left
	}
	return i32(best)
}

@(private = "file")
emit_into :: proc(out: ^[dynamic]Emit, es: []Emit, src: int) {
	for e in es {
		append(out, Emit{strings.clone(e.line, context.temp_allocator), e.kind, src})
	}
}

// Read one source and return the kipp lines it produced. The lines live in
// the temp allocator and die with the loop pass.
src_ready :: proc(ss: ^Sources, fd: posix.FD) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	ss.last = nil

	for s in ss.list {
		if s.kind == .Dbus && s.fd == fd && !s.done {
			if !dbus_ready(s, ss.vm, &out) {
				// The connection dropped. Without this the fd stays
				// readable and the loop spins.
				s.done = true
				s.dead = true
			}
			return out[:]
		}
	}

	for s in ss.list {
		if s.fd != fd || s.done do continue
		ss.last = s

		eof := false
		chunk: [4096]byte
		for {
			// read, not recv: an exec source is a pipe, and recv fails on
			// anything that is not a socket.
			n := posix.read(fd, raw_data(chunk[:]), len(chunk))
			if n > 0 {
				if len(s.buf) + int(n) > MAX_BUF {
					fmt.eprintfln(
`kippsrv: source %q sent over %d bytes with no complete unit in them, so they
         were discarded. Its framing does not match what it produces.
         [E-framing] See DIAGNOSTICS.md.`, s.name, MAX_BUF)
					clear(&s.buf)
				} else {
					append(&s.buf, ..chunk[:int(n)])
				}
				continue
			}
			if n == 0 {
				eof = true
				break
			}
			e := posix.errno()
			if e == .EAGAIN || e == .EWOULDBLOCK do break
			eof = true
			break
		}

		// Deframe what arrived. This has to run before the end is handled:
		// data and EOF often land in the same pass, and a short-lived
		// command is the normal case, not the exception.
		for {
			unit, got := take(s)
			if !got do break
			if len(unit) == 0 {
				fmt.eprintfln(
`kippsrv: source %q stopped: its framing produced an empty unit, which would
         repeat for ever. Check the framing block for this source in
         config.lua. [E-framing] See DIAGNOSTICS.md.`, s.name)
				s.dead = true
				break
			}
			if _, is_lines := s.framing.(Lines); is_lines {
				emit_into(&out, vm_feed(ss.vm, s.adapter, string(unit)), s.id)
			} else {
				emit_into(&out, vm_feed_bytes(ss.vm, s.adapter, unit), s.id)
			}
			consumed(s, unit)
		}

		if eof {
			// A last line with no trailing newline is still a line.
			if _, is_lines := s.framing.(Lines); is_lines && len(s.buf) > 0 {
				emit_into(&out, vm_feed(ss.vm, s.adapter, string(s.buf[:])), s.id)
				clear(&s.buf)
			}
			emit_into(&out, vm_flush(ss.vm, s.adapter), s.id)
			posix.close(s.fd)
			s.fd = -1
			s.done = true

			// A poll ends every cycle by design, and a one-shot seed ends
			// once and stays true. Neither is a death. A socket closing is,
			// but it is worth dialling again before giving up.
			if s.every > 0 do s.due = now_ms() + s.every
		}
		break
	}
	return out[:]
}

// Run every timer that is due, and start every exec source whose period came
// round again.
// The watcher's list, through the adapter of the source that owns it.
watcher_facts :: proc(ss: ^Sources) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		if s.kind == .Dbus && s.adapter != NO_ADAPTER {
			watcher_pass(ss.vm, s.adapter, &out, s.id)
		}
	}
	return out[:]
}

// A run that changed nothing is asked for less often. Anything new resets it.
// By the source src_ready just handled: a run that ended has closed its fd.
src_report :: proc(ss: ^Sources, changed: int) {
	s := ss.last
	if s == nil || !s.done do return                 // still reading, not a cycle
	if s.kind != .Exec || s.base <= 0 || s.steady do return

	if changed > 0 {
		s.idle = 0
		s.every = s.base
		return
	}
	s.idle += 1
	if s.idle >= IDLE_BEFORE_BACKOFF {
		s.every = min(s.every * 2, min(s.base * BACKOFF_MAX_FACTOR,
		                               i64(BACKOFF_CEILING_MS)))
	}
}

// Sources that died since the last pass, so the store can mark their facts.
src_reap :: proc(ss: ^Sources) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	for s in ss.list {
		if s.dead && !s.reaped {
			s.reaped = true
			append(&out, s.id)
		}
	}
	return out[:]
}

src_tick :: proc(ss: ^Sources, now: i64) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		if now < s.due do continue

		switch {
		case s.kind == .Timer:
			s.due = now + s.every
			emit_into(&out, vm_call(ss.vm, s.adapter, "tick"), s.id)
		case s.done && s.every > 0:
			// `dead` means the facts are stale. It does not mean stop
			// trying. A socket keeps dialling, because whatever served it
			// can come back at any moment. An exec that will not start three
			// times running has nothing left to say.
			if s.dead && s.kind != .Sock do continue

			if s.kind == .Sock ? redial(s) : respawn(s) {
				s.fails = 0
				s.dead = false
				s.reaped = false     // so a later death marks its facts again
			} else {
				s.fails += 1
				s.due = now + s.every
				if s.fails >= 3 do s.dead = true
			}
		}
	}
	return out[:]
}

// Write through a temporary file and rename, so a reader never sees half a
// file. A reader watches the directory, because a rename makes a new inode.
write_atomic :: proc(path: string, data: []byte) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)

	fd := posix.open(ctmp, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	n := posix.write(fd, raw_data(data), c.size_t(len(data)))
	posix.close(fd)

	if int(n) != len(data) {
		posix.unlink(ctmp)
		return false
	}
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.rename(ctmp, cpath) != 0 {
		posix.unlink(ctmp)
		return false
	}
	return true
}
