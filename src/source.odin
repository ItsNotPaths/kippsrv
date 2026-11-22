// Foreign sources. Four kinds, none of them a domain.
//
//   exec   spawn a command and read its output
//   sock   connect to a unix socket
//   timer  fire on a period
//   dbus   subscribe to a signal          (dbus.odin, not here)
//
// A source owns the descriptor and cuts its output into lines, so an adapter
// gets whole lines and never reassembles a torn one.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

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
	buf:     [dynamic]byte,
	exec:    string,     // the command, kept so it can be run again
	input:   posix.FD,   // exec: the child's stdin, or -1
	path:    string,     // sock, kept so it can be dialled again
	base:    i64,        // the period the configuration asked for
	every:   i64,        // the period in use, which backoff can stretch
	idle:    int,        // cycles in a row that changed nothing
	moved:   int,        // lines this cycle that passed the store
	settled: bool,       // this cycle's outcome has been counted
	thr:     Throttle,   // how often this source may reach its adapter
	held:    [dynamic]byte,  // newest unit, waiting for the throttle window
	gap_due: i64,        // earliest next adapter call, when min_gap is set
	due:     i64,        // next fire on the monotonic clock
	done:    bool,       // ended for now
	fails:   int,        // runs in a row that did not start
	dead:    bool,       // gone, until a restart works
	said:    Status,     // what status/<name> last said
	retains: []string,   // its claim, borrowed from the config
	refused: bool,       // a retain outside the claim was reported
	bus:     ^Bus,       // dbus only
}

Status :: enum {Unsaid, Online, Offline}

@(private = "file", rodata)
STATUS_WORD := [Status]string{.Unsaid = "", .Online = "online", .Offline = "offline"}

Sources :: struct {
	vm:      ^Vm,
	list:    [dynamic]^Source,
	next_id: int,
	warned:  bool,        // the poll set overflowed, reported once
}

MAX_BUF   :: 1 << 20   // a source that never ends a line must not grow without end
RETRY_MS  :: 2000      // how often a closed socket is dialled again

// A poll that learns nothing still costs a fork, an exec and a Lua call. The
// store spares the consumers, not the machine.
//
// A source with a period is slowed by stretching it. A source that is handed
// its data cannot be slowed that way, so `min_gap` holds the newest unit back
// instead. Both mean the same thing: how often this source reaches Lua.
Throttle :: struct {
	idle:    int,   // quiet cycles before the period stretches
	factor:  int,   // most the period may stretch, as a multiple of the base
	ceiling: i64,   // ms. Absolute cap on a stretched period
	min_gap: i64,   // ms. Least time between two adapter calls. 0 is off
}

THROTTLE :: Throttle{idle = 3, factor = 16, ceiling = 60_000, min_gap = 0}

// ------------------------------------------------------------------ reaping

// A polling source forks once a period. Without this the process table fills
// and fork eventually fails for the whole session.
//
// sh exits 127 for a command it cannot find and 126 for one it cannot run.
// That run did not start, the same as a fork that failed.
src_reap :: proc(ss: ^Sources) {
	for {
		status: c.int
		pid := posix.waitpid(-1, &status, {.NOHANG})
		if pid <= 0 do return
		for s in ss.list {
			if s.pid != pid do continue
			s.pid = 0
			code := posix.WEXITSTATUS(status) if posix.WIFEXITED(status) else 0
			if code == 126 || code == 127 {
				failed_run(s)
			} else {
				s.fails = 0
			}
			break
		}
	}
}

// Three in a row and a source is dead. One that runs once has no second try.
@(private = "file")
failed_run :: proc(s: ^Source) {
	s.fails += 1
	if s.fails >= 3 || s.every == 0 do s.dead = true
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
	s.held = make([dynamic]byte)
	s.thr = THROTTLE
	if s.kind != .Exec do s.input = -1
	ss.next_id += 1
	s.id = ss.next_id
	append(&ss.list, s)
	return s
}

// `sh -c` the command. Its stdout is read, its stdin is the way back.
@(private = "file")
spawn :: proc(command: string) -> (out, input: posix.FD, pid: posix.pid_t, ok: bool) {
	// Built before the fork. Between fork and exec only async-signal-safe
	// calls are allowed, and an allocator whose lock another thread held at
	// fork time will never unlock in the child.
	argv := [4]cstring{"/bin/sh", "-c", strings.clone_to_cstring(command, context.temp_allocator), nil}

	reads, writes: [2]posix.FD
	if posix.pipe(&reads) != .OK do return -1, -1, 0, false
	if posix.pipe(&writes) != .OK {
		posix.close(reads[0]); posix.close(reads[1])
		return -1, -1, 0, false
	}

	pid = posix.fork()
	if pid < 0 {
		for fd in ([]posix.FD{reads[0], reads[1], writes[0], writes[1]}) do posix.close(fd)
		return -1, -1, 0, false
	}
	if pid == 0 {
		posix.dup2(reads[1], posix.STDOUT_FILENO)
		posix.dup2(writes[0], posix.STDIN_FILENO)
		for fd in ([]posix.FD{reads[0], reads[1], writes[0], writes[1]}) do posix.close(fd)
		posix.signal(.SIGPIPE, auto_cast posix.SIG_DFL)   // an ignored signal survives exec
		posix.execv("/bin/sh", raw_data(argv[:]))
		posix._exit(127)
	}

	posix.close(reads[1])
	posix.close(writes[0])
	set_flags(reads[0])
	set_flags(writes[1])
	return reads[0], writes[1], pid, true
}

// A command that ends and is run again on a period. `every` of 0 runs it once.
src_exec :: proc(ss: ^Sources, name, command: string, adapter: Adapter,
                 every: i64 = 0) -> (source: ^Source, ok: bool) {
	out, input, pid := spawn(command) or_return
	return add(ss, new_clone(Source{
		name = strings.clone(name), kind = .Exec, fd = out, input = input, pid = pid,
		adapter = adapter, exec = strings.clone(command), every = every, base = every,
	})), true
}

// Its adapter and its state survive, so a poll builds on the last run.
@(private = "file")
respawn :: proc(s: ^Source) -> bool {
	s.fd, s.input, s.pid = spawn(s.exec) or_return
	s.done = false
	s.settled = false
	clear(&s.buf)
	return true
}

// Connect to a unix socket and read it.
src_sock :: proc(ss: ^Sources, name, path: string,
                 adapter: Adapter) -> (^Source, bool) {
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
		adapter = adapter, every = RETRY_MS, base = RETRY_MS,
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
	s.settled = false
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

// ------------------------------------------------------------- outbound

// A line back to the source: an exec's stdin, or a sock's connection.
//
// The line limit is what makes a write whole or nothing: a pipe write under
// PIPE_BUF cannot interleave with another writer's.
src_send :: proc(s: ^Source, data: []byte) -> bool {
	if len(data) == 0 || len(data) > MAX_LINE || s.done do return false
	fd: posix.FD
	#partial switch s.kind {
	case .Exec: fd = s.input
	case .Sock: fd = s.fd
	case:       return false
	}
	return fd >= 0 && int(posix.write(fd, raw_data(data), c.size_t(len(data)))) == len(data)
}

src_close :: proc(ss: ^Sources) {
	for s in ss.list {
		// The bus owns its descriptor, and two sources on one connection --
		// sd_bus_default_user hands back the same one -- hold the same fd.
		// Closing it here as well is a second close of a live descriptor, and
		// basu asserts on the third.
		if s.kind == .Dbus {
			dbus_close(s)
		} else if s.fd >= 0 {
			posix.close(s.fd)
		}
		if s.input >= 0 do posix.close(s.input)
		if s.pid > 0 do posix.kill(s.pid, .SIGTERM)
		delete(s.exec)
		delete(s.path)
		delete(s.buf)
		delete(s.held)
		delete(s.name)
		free(s)
	}
	delete(ss.list)
}

// -------------------------------------------------------------- deframing

// One whole line, or nothing. The caller reads again and asks later.
@(private = "file")
take :: proc(s: ^Source) -> ([]byte, bool) {
	blank := 0      // a blank line carries nothing
	for blank < len(s.buf) && s.buf[blank] == '\n' do blank += 1
	if blank > 0 {
		copy(s.buf[:], s.buf[blank:])
		resize(&s.buf, len(s.buf) - blank)
	}
	for b, i in s.buf do if b == '\n' do return s.buf[:i], true
	return nil, false
}

@(private = "file")
consumed :: proc(s: ^Source, unit: []byte) {
	n := min(len(unit) + 1, len(s.buf))   // the newline
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
		if len(s.held) > 0 do nearest(&best, s.gap_due, now)
		if s.every == 0 || s.dead do continue
		// A source that is running has nothing due. Its period says when to
		// start it again, not when to look at it, and a socket that is
		// connected is running. Counting one gave poll a zero timeout and
		// turned the loop into a spin.
		if s.kind != .Timer && !s.done do continue
		nearest(&best, s.due, now)
	}
	return i32(best)
}

@(private = "file")
nearest :: proc(best: ^i64, due, now: i64) {
	left := max(0, due - now)
	if best^ < 0 || left < best^ do best^ = left
}

@(private = "file")
emit_into :: proc(out: ^[dynamic]Emit, es: []Emit, src: int) {
	for e in es {
		append(out, Emit{strings.clone(e.line, context.temp_allocator), src})
	}
}

@(private = "file")
feed :: proc(v: ^Vm, s: ^Source, unit: []byte) -> []Emit {
	return vm_feed(v, s.adapter, string(unit))
}

// One framed unit, either to the adapter now or held until the window opens.
// Holding keeps the newest unit only: the point is to skip the Lua call, so
// the units in between are dropped. A source whose units are events rather
// than current values must not be given a `min_gap`.
src_feed :: proc(v: ^Vm, s: ^Source, out: ^[dynamic]Emit, unit: []byte) {
	if s.thr.min_gap > 0 {
		now := now_ms()
		if now < s.gap_due {
			clear(&s.held)
			append(&s.held, ..unit)
			return
		}
		s.gap_due = now + s.thr.min_gap
	}
	emit_into(out, feed(v, s, unit), s.id)
}

// Read one source and return the kipp lines it produced. The lines live in
// the temp allocator and die with the loop pass.
src_ready :: proc(ss: ^Sources, fd: posix.FD) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)

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

		eof := false
		chunk: [4096]byte
		for {
			// read, not recv: an exec source is a pipe, and recv fails on
			// anything that is not a socket.
			n := posix.read(fd, raw_data(chunk[:]), len(chunk))
			if n > 0 {
				if len(s.buf) + int(n) > MAX_BUF {
					fmt.eprintfln(
`kippsrv: source %q sent over %d bytes with no newline in them, so they were
         discarded. [E-framing] See DIAGNOSTICS.md.`, s.name, MAX_BUF)
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
			src_feed(ss.vm, s, &out, unit)
			consumed(s, unit)
		}

		if eof {
			// A last line with no trailing newline is still a line.
			if len(s.buf) > 0 {
				src_feed(ss.vm, s, &out, s.buf[:])
				clear(&s.buf)
			}
			// A held unit is the source's last word. It goes before the flush.
			if len(s.held) > 0 {
				emit_into(&out, feed(ss.vm, s, s.held[:]), s.id)
				clear(&s.held)
			}
			emit_into(&out, vm_flush(ss.vm, s.adapter), s.id)
			posix.close(s.fd)
			s.fd = -1
			if s.input >= 0 do posix.close(s.input)
			s.input = -1
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
// What the servers hold, through the adapter of the source that owns each.
// Both are the same shape: state in Odin, named by Lua, once per pass.
watcher_facts :: proc(ss: ^Sources) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		if s.kind == .Dbus && s.adapter != NO_ADAPTER {
			watcher_pass(ss.vm, s.adapter, &out, s.id)
			notify_pass(ss.vm, s.adapter, &out, s.id)
		}
	}
	return out[:]
}

// A line that passed the store, credited to the source that produced it.
src_moved :: proc(ss: ^Sources, id: int) {
	for s in ss.list {
		if s.id == id {
			s.moved += 1
			return
		}
	}
}

// A cycle that changed nothing is asked for less often. Anything new resets it.
// Only a source with a work period has one to stretch: a socket's `every` is
// how often it is dialled again, not how often it is read.
@(private = "file")
back_off :: proc(s: ^Source) {
	if s.kind != .Exec && s.kind != .Timer do return
	if s.base <= 0 || s.thr.idle <= 0 do return

	if s.moved > 0 {
		s.idle = 0
		s.every = s.base
		return
	}
	s.idle += 1
	if s.idle >= s.thr.idle {
		s.every = min(s.every * 2, min(s.base * i64(s.thr.factor), s.thr.ceiling))
	}
}

// Once a pass, after everything a source produced has been through the store.
// A cycle is one run of an exec source, or one beat of a timer.
src_settle :: proc(ss: ^Sources) {
	for s in ss.list {
		if s.settled || !(s.done || s.kind == .Timer) do continue
		back_off(s)
		s.moved = 0
		s.settled = true
	}
}

// A retain must fall inside its source's claim. kippsrv's own lines, source
// 0, and events need none.
src_may_retain :: proc(ss: ^Sources, e: Emit) -> bool {
	if e.src == 0 || !strings.has_prefix(e.line, "retain\t") do return true
	for s in ss.list {
		if s.id != e.src do continue
		topic := topic_of(e.line)
		for pattern in s.retains do if matches(pattern, topic) do return true
		if !s.refused {
			s.refused = true
			fmt.eprintfln(
`kippsrv: source %q retained %q, outside its claim, and it was dropped. Its
         file's retains list does not cover what its adapter writes.
         [E-claim] See DIAGNOSTICS.md.`, s.name, topic)
		}
		return false
	}
	return true
}

// The status/<name> lines that changed since the last pass. A dead source is
// offline, so a reader knows its facts are last-known.
src_status :: proc(ss: ^Sources) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		now := Status.Offline if s.dead else .Online
		if s.said == now do continue
		topic := fmt.tprintf("status/%s", s.name)
		if !is_topic(topic) do continue
		s.said = now
		// (hole status-claim :tags broker) names no claim; v2 adds retains=<pattern>, so a reader matches its own topics against it.
		append(&out, Emit{fmt.tprintf("retain\t%s\tstate=%s", topic, STATUS_WORD[now]), 0})
	}
	return out[:]
}

src_tick :: proc(ss: ^Sources, now: i64) -> []Emit {
	out := make([dynamic]Emit, context.temp_allocator)
	for s in ss.list {
		// A held unit goes out when its window closes, so a source that then
		// falls quiet is not left showing the value before last.
		if len(s.held) > 0 && now >= s.gap_due {
			emit_into(&out, feed(ss.vm, s, s.held[:]), s.id)
			clear(&s.held)
			s.gap_due = now + s.thr.min_gap
		}
		if now < s.due do continue

		switch {
		case s.kind == .Timer:
			s.due = now + s.every
			s.settled = false
			emit_into(&out, vm_call(ss.vm, s.adapter, "tick"), s.id)
		case s.done && s.every > 0:
			// `dead` means the source is offline. It does not mean stop
			// trying. A socket keeps dialling, because whatever served it
			// can come back at any moment. An exec that will not start three
			// times running has nothing left to say.
			if s.dead && s.kind != .Sock do continue

			started := redial(s) if s.kind == .Sock else respawn(s)
			if !started {
				failed_run(s)
				s.due = now + s.every
			} else if s.kind == .Sock {
				s.fails = 0       // an exec's run is judged when it exits, in src_reap
				s.dead = false
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
