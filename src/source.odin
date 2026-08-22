// Foreign sources. Four kinds, none of them a domain.
//
//   exec   spawn a command and read its output
//   sock   connect to a unix socket
//   timer  fire on a period
//   dbus   subscribe to a signal          (dbus.odin, not here)
//
// A source owns the descriptor and the framing. An adapter gets whole units
// and never a partial one, so nothing in Lua reassembles a torn line or a
// torn frame.
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
}

Source :: struct {
	name:    string,
	kind:    Kind,
	fd:      posix.FD,
	pid:     posix.pid_t,
	adapter: Adapter,
	framing: Framing,
	buf:     [dynamic]byte,
	every:   i64,   // timer period in ms
	due:     i64,   // timer, next fire on the monotonic clock
	done:    bool,  // the descriptor reached EOF and flush has run
}

Sources :: struct {
	vm:   ^Vm,
	list: [dynamic]^Source,
}

MAX_BUF :: 1 << 20   // a source that never frames must not grow without end

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
	append(&ss.list, s)
	return s
}

// Spawn a command and read its stdout.
src_exec :: proc(ss: ^Sources, name: string, argv: []string,
                 adapter: Adapter, framing: Framing = Lines{}) -> (^Source, bool) {
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
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Exec, fd = fds[0], pid = pid,
		adapter = adapter, framing = framing,
	})), true
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
		name = strings.clone(name), kind = .Sock, fd = fd,
		adapter = adapter, framing = framing,
	})), true
}

// Fire on a period. It carries no data, so the adapter's `tick` runs instead
// of `feed`.
src_timer :: proc(ss: ^Sources, name: string, every_ms: i64,
                  adapter: Adapter) -> (^Source, bool) {
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Timer, fd = -1,
		adapter = adapter, every = every_ms, due = now_ms() + every_ms,
	})), true
}

src_close :: proc(ss: ^Sources) {
	for s in ss.list {
		if s.fd >= 0 do posix.close(s.fd)
		if s.pid > 0 do posix.kill(s.pid, .SIGTERM)
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
	for s in ss.list {
		if s.fd < 0 || s.done || n == len(dst) do continue
		dst[n] = {fd = s.fd, events = {.IN}}
		n += 1
	}
	return n
}

// The nearest timer, in ms, for the poll timeout. -1 when none is pending.
src_timeout :: proc(ss: ^Sources, now: i64) -> i32 {
	best: i64 = -1
	for s in ss.list {
		if s.kind != .Timer do continue
		left := max(0, s.due - now)
		if best < 0 || left < best do best = left
	}
	return i32(best)
}

@(private = "file")
emit_into :: proc(out: ^[dynamic]Emit, es: []Emit) {
	for e in es {
		append(out, Emit{strings.clone(e.line, context.temp_allocator), e.kind})
	}
}

// Read one source and return the kipp lines it produced. The lines live in
// the temp allocator and die with the loop pass.
src_ready :: proc(ss: ^Sources, fd: posix.FD) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)

	for s in ss.list {
		if s.fd != fd || s.done do continue

		eof := false
		chunk: [4096]byte
		for {
			// read, not recv: an exec source is a pipe, and recv fails on
			// anything that is not a socket.
			n := posix.read(fd, raw_data(chunk[:]), len(chunk))
			if n > 0 {
				if len(s.buf) + int(n) > MAX_BUF {
					fmt.eprintfln("source %s: over %d bytes unframed, dropped",
					              s.name, MAX_BUF)
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
			if _, is_lines := s.framing.(Lines); is_lines {
				emit_into(&out, vm_feed(ss.vm, s.adapter, string(unit)))
			} else {
				emit_into(&out, vm_feed_bytes(ss.vm, s.adapter, unit))
			}
			consumed(s, unit)
		}

		if eof {
			// A last line with no trailing newline is still a line.
			if _, is_lines := s.framing.(Lines); is_lines && len(s.buf) > 0 {
				emit_into(&out, vm_feed(ss.vm, s.adapter, string(s.buf[:])))
				clear(&s.buf)
			}
			emit_into(&out, vm_flush(ss.vm, s.adapter))
			s.done = true
			posix.close(s.fd)
			s.fd = -1
		}
		break
	}
	return out[:]
}

// Run every timer that is due.
src_tick :: proc(ss: ^Sources, now: i64) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		if s.kind != .Timer || now < s.due do continue
		s.due = now + s.every
		emit_into(&out, vm_call(ss.vm, s.adapter, "tick"))
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
