// The kipp wire. See the kipp repo's SPEC.md.
//
// This is our own implementation, not a vendored one. The protocol is the
// contract, so two implementations that drift still interoperate.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

MAX_LINE   :: 1024
MAX_FIELDS :: 32
MAX_CONN   :: 32

// ---------------------------------------------------------------- parsing

Msg :: struct {
	kind: string,
	subj: [dynamic]string,
	attr: map[string]string,
}

// Field 1 is the kind. Fields after it are positional subject up to the first
// one holding '=', then key=value. A leading '@' field is reserved metadata.
parse :: proc(line: string, allocator := context.allocator) -> (m: Msg, ok: bool) {
	m.subj = make([dynamic]string, allocator)
	m.attr = make(map[string]string, allocator = allocator)

	rest := line
	for f in strings.split_iterator(&rest, "\t") {
		if f == "" do continue
		if m.kind == "" {
			if strings.has_prefix(f, "@") do continue
			m.kind = f
			continue
		}
		if i := strings.index_byte(f, '='); i > 0 {
			if len(m.attr) < MAX_FIELDS do m.attr[f[:i]] = f[i + 1:]
		} else if len(m.subj) < MAX_FIELDS {
			append(&m.subj, f)
		}
	}
	return m, m.kind != ""
}

is_cmd :: proc(m: ^Msg) -> bool {
	return len(m.kind) > 0 && m.kind[0] >= 'A' && m.kind[0] <= 'Z'
}

// --------------------------------------------------------------- building

Out :: struct {
	buf:  [MAX_LINE]byte,
	len:  int,
	over: bool,
}

// Tabs and newlines frame the protocol, so no value may hold one. Every
// control character goes the same way.
@(private = "file")
sanitize :: proc(dst: []byte, src: string) -> int {
	n := 0
	for i in 0 ..< len(src) {
		ch := src[i]
		if ch >= 0x20 && ch != 0x7f && n < len(dst) {
			dst[n] = ch
			n += 1
		}
	}
	return n
}

begin :: proc(o: ^Out, kind: string) {
	o.over = false
	o.len = sanitize(o.buf[:], kind)
}

// One field. An '=' in it makes it an attribute. That is the whole rule.
add :: proc(o: ^Out, format: string, args: ..any) {
	if o.over do return

	raw := fmt.tprintf(format, ..args)
	tmp: [MAX_LINE]byte
	n := sanitize(tmp[:], raw)

	if o.len + 1 + n >= len(o.buf) {
		o.over = true
		return
	}
	o.buf[o.len] = '\t'
	o.len += 1
	copy(o.buf[o.len:], tmp[:n])
	o.len += n
}

str :: proc(o: ^Out) -> (string, bool) {
	if o.over do return "", false
	return string(o.buf[:o.len]), true
}

// ------------------------------------------------------------- read buffer

@(private = "file")
Rdbuf :: struct {
	b:    [MAX_LINE + 1]byte,
	len:  int,
	skip: bool,   // discarding the tail of an overlong line
}

@(private = "file")
Pull :: enum {Data, Empty, Gone}

@(private = "file")
rd_pull :: proc(fd: posix.FD, r: ^Rdbuf) -> Pull {
	if r.len == len(r.b) do return .Data   // full. rd_take decides what that means

	n := posix.recv(fd, &r.b[r.len], c.size_t(len(r.b) - r.len), {})
	if n > 0 {
		r.len += int(n)
		return .Data
	}
	if n == 0 do return .Gone

	e := posix.errno()
	return .Empty if e == .EAGAIN || e == .EWOULDBLOCK else .Gone
}

@(private = "file")
Take :: enum {Line, Need, TooLong}

@(private = "file")
rd_take :: proc(r: ^Rdbuf, out: []byte) -> (n: int, what: Take) {
	for {
		nl := -1
		for i in 0 ..< r.len {
			if r.b[i] == '\n' {
				nl = i
				break
			}
		}
		if nl < 0 {
			if r.len < len(r.b) do return 0, .Need
			r.len = 0
			r.skip = true
			return 0, .TooLong
		}

		got := !r.skip   // a skipped line ends at this newline
		if got do copy(out, r.b[:nl])
		r.skip = false

		used := nl + 1
		r.len -= used
		copy(r.b[:], r.b[used:used + r.len])
		if got do return nl, .Line
	}
}

// ---------------------------------------------------------------- server

Conn :: struct {
	fd:  posix.FD,
	r:   Rdbuf,
	out: [dynamic]byte,   // this pass's lines, written in one send
	eof: bool,            // it will send no more commands. It still reads
}

// A unix socket accounts per message, not per byte: one send of one line
// costs about 766 bytes of kernel buffer. Batching a pass into one send holds
// roughly ten times as many lines before a stalled consumer runs out.
MAX_OUT :: 256 * 1024

Server :: struct {
	fd:      posix.FD,
	path:    string,
	greet:   string,
	conns:   [dynamic]Conn,
	on_dump: proc(s: ^Server, fd: posix.FD),
	on_cmd:  proc(s: ^Server, m: ^Msg, fd: posix.FD),
}

@(private = "file")
sock_addr :: proc(path: string) -> (addr: posix.sockaddr_un, ok: bool) {
	if len(path) >= len(addr.sun_path) do return addr, false
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], transmute([]c.char)path)
	return addr, true
}

@(private = "file")
set_flags :: proc(fd: posix.FD) -> bool {
	if posix.fcntl(fd, .SETFL, posix.O_Flags{.NONBLOCK}) < 0 do return false
	return posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC) >= 0
}

// One line plus its newline, straight out. Used only for the greeting, before
// a consumer has a queue.
@(private = "file")
wr :: proc(fd: posix.FD, line: string) -> bool {
	buf: [MAX_LINE + 1]byte
	if len(line) >= len(buf) do return false

	copy(buf[:], line)
	buf[len(line)] = '\n'
	n := len(line) + 1

	return int(posix.send(fd, &buf[0], c.size_t(n), {.NOSIGNAL})) == n
}

@(private = "file")
queue :: proc(c: ^Conn, line: string) -> bool {
	if len(c.out) + len(line) + 1 > MAX_OUT do return false
	append(&c.out, line)
	append(&c.out, '\n')
	return true
}

// A live owner answers a connect. A stale socket does not.
@(private = "file")
in_use :: proc(path: string) -> bool {
	addr := sock_addr(path) or_return
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return false
	defer posix.close(fd)
	return posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK
}

serve :: proc(path, greet: string) -> (s: ^Server, ok: bool) {
	if in_use(path) do return nil, false
	addr := sock_addr(path) or_return

	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return nil, false

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(cpath)

	if !set_flags(fd) ||
	   posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK ||
	   posix.listen(fd, 8) != .OK {
		posix.close(fd)
		return nil, false
	}

	// The mode a bind leaves is the umask's, so a default umask gives 0755.
	// Inside /run/user/$UID that is masked by the directory, but the path is
	// an argument and can point anywhere. Say it rather than assume it.
	posix.chmod(cpath, {.IRUSR, .IWUSR})

	s = new(Server)
	s.fd = fd
	s.path = strings.clone(path)
	s.greet = strings.clone(greet)
	s.conns = make([dynamic]Conn)
	return s, true
}

stop :: proc(s: ^Server) {
	if s == nil do return
	for &c in s.conns do posix.close(c.fd)
	posix.close(s.fd)
	posix.unlink(strings.clone_to_cstring(s.path, context.temp_allocator))
	delete(s.conns)
	delete(s.path)
	delete(s.greet)
	free(s)
}

// Descriptors, for the event loop. The set changes as consumers come and go,
// so the caller refills it each time round.
srv_fds :: proc(s: ^Server, dst: []posix.pollfd) -> int {
	if len(dst) == 0 do return 0
	dst[0] = {fd = s.fd, events = {.IN}}
	n := 1
	for q in s.conns {
		// A half-closed consumer is permanently readable, so polling it
		// would spin. It is reaped when a write to it fails.
		if q.eof || n == len(dst) do continue
		dst[n] = {fd = q.fd, events = {.IN}}
		n += 1
	}
	return n
}

@(private = "file")
drop :: proc(s: ^Server, i: int) {
	posix.close(s.conns[i].fd)
	delete(s.conns[i].out)
	unordered_remove(&s.conns, i)
}

send_to :: proc(s: ^Server, fd: posix.FD, line: string) {
	for i in 0 ..< len(s.conns) {
		if s.conns[i].fd != fd do continue
		if !queue(&s.conns[i], line) do drop(s, i)
		return
	}
}

broadcast :: proc(s: ^Server, line: string) {
	i := 0
	for i < len(s.conns) {
		if queue(&s.conns[i], line) {
			i += 1
		} else {
			drop(s, i)   // unordered_remove moves the last conn into i
		}
	}
}

// Send each consumer its pass in one write. A write that only partly lands
// keeps its remainder for the next pass, so a consumer that stalls for a
// moment is not dropped for it. A consumer that stalls past MAX_OUT is.
srv_flush :: proc(s: ^Server) {
	i := 0
	for i < len(s.conns) {
		q := &s.conns[i]
		if len(q.out) == 0 {
			i += 1
			continue
		}
		n := int(posix.send(q.fd, raw_data(q.out), c.size_t(len(q.out)),
		                    {.NOSIGNAL}))
		if n <= 0 {
			e := posix.errno()
			if e == .EAGAIN || e == .EWOULDBLOCK {
				i += 1          // the queue keeps, we try again next pass
				continue
			}
			drop(s, i)
			continue
		}
		if n < len(q.out) {
			copy(q.out[:], q.out[n:])
			resize(&q.out, len(q.out) - n)
		} else {
			clear(&q.out)
		}
		i += 1
	}
}

send_error :: proc(s: ^Server, fd: posix.FD, code, cmd, msg: string) {
	o: Out
	begin(&o, "error")
	add(&o, "%s", code)
	if cmd != "" do add(&o, "cmd=%s", cmd)
	if msg != "" do add(&o, "msg=%s", msg)
	if line, ok := str(&o); ok do send_to(s, fd, line)
}

@(private = "file")
accept_one :: proc(s: ^Server) {
	fd := posix.accept(s.fd, nil, nil)
	if fd < 0 do return
	if !set_flags(fd) || len(s.conns) == MAX_CONN || !wr(fd, s.greet) {
		posix.close(fd)
		return
	}
	append(&s.conns, Conn{fd = fd})

	if s.on_dump != nil do s.on_dump(s, fd)
	send_to(s, fd, "sync\tstate")
}

@(private = "file")
read_conn :: proc(s: ^Server, i: int) {
	line: [MAX_LINE]byte

	for {
		n, what := rd_take(&s.conns[i].r, line[:])
		switch what {
		case .TooLong:
			send_error(s, s.conns[i].fd, "toolong", "", "line over 1024 bytes")
			continue
		case .Need:
			switch rd_pull(s.conns[i].fd, &s.conns[i].r) {
			case .Empty: return
			case .Gone:
				// EOF on the read side means it will send nothing more. It
				// does not mean it stopped reading, and a client that sends
				// one command then only listens is normal. Keep writing to
				// it until a write fails.
				s.conns[i].eof = true
				return
			case .Data:  continue
			}
		case .Line:
			m, good := parse(string(line[:n]), context.temp_allocator)
			if !good {
				send_error(s, s.conns[i].fd, "badcmd", "", "unparsable line")
				continue
			}
			// A consumer sends commands, which are uppercase. It may not
			// send a fact. Leaving this to each handler makes the direction
			// rule a convention; here it is a boundary, so nothing that
			// connects can forge state for everything else that reads.
			if !is_cmd(&m) {
				send_error(s, s.conns[i].fd, "badcmd", m.kind,
				           "a consumer sends commands, not facts")
				continue
			}
			if s.on_cmd != nil do s.on_cmd(s, &m, s.conns[i].fd)
		}
	}
}

// By fd, not by index: this call can drop a consumer, and a caller part way
// through its poll set must not have the rest shift under it.
srv_ready :: proc(s: ^Server, fd: posix.FD) {
	if fd == s.fd {
		accept_one(s)
		return
	}
	for c, i in s.conns {
		if c.fd == fd {
			read_conn(s, i)
			return
		}
	}
}
