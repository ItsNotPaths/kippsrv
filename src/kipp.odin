// The kipp wire. See the kipp repo's SPEC.md.
//
// Our own implementation, not a vendored one: the protocol is the contract.
package kippsrv

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"

MAX_LINE   :: 1024
MAX_FIELDS :: 32
MAX_CONN   :: 32
MAX_SUBS   :: 64     // patterns one connection may hold

// ---------------------------------------------------------------- parsing

Msg :: struct {
	verb:    string,
	topic:   string,
	payload: map[string]string,
}

// Field 1 is the verb, field 2 the topic, and every field after is key=value.
// A field after the topic with no '=' is skipped.
parse :: proc(line: string, allocator := context.allocator) -> (m: Msg, ok: bool) {
	m.payload = make(map[string]string, allocator = allocator)

	rest := line
	for f in strings.split_iterator(&rest, "\t") {
		switch {
		case m.verb == "":  m.verb = f
		case m.topic == "": m.topic = f
		case:
			i := strings.index_byte(f, '=')
			if i > 0 && len(m.payload) < MAX_FIELDS do m.payload[f[:i]] = f[i + 1:]
		}
	}
	return m, m.verb != ""
}

// The second field.
topic_of :: proc(line: string) -> string {
	_, _, rest := strings.partition(line, "\t")
	topic, _, _ := strings.partition(rest, "\t")
	return topic
}

// fnmatch(3) without FNM_PATHNAME, so '*' crosses '/'.
matches :: proc(pattern, topic: string) -> bool {
	return posix.fnmatch(cstr(pattern), cstr(topic), {}) == 0
}

is_pattern :: proc(pattern: string) -> bool {
	for ch in transmute([]byte)pattern do if ch < 0x20 || ch == 0x7f do return false
	return len(pattern) > 0
}

// The first segment is a kind. The rest hold no control character, '*', '?'
// or '['.
is_topic :: proc(topic: string) -> bool {
	kind, _, rest := strings.partition(topic, "/")
	for ch in transmute([]byte)rest {
		if ch < 0x20 || ch == 0x7f || ch == '*' || ch == '?' || ch == '[' do return false
	}
	return is_word(kind)
}

// A kind or a key: lowercase letters, digits and underscores, never a number.
is_word :: proc(s: string) -> bool {
	number := true
	for ch in transmute([]byte)s {
		switch ch {
		case 'a' ..= 'z', '_': number = false
		case '0' ..= '9':
		case: return false
		}
	}
	return len(s) > 0 && !number
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

// What has been built so far, valid or not. For a writer checking its own work.
line_of :: proc(o: ^Out) -> string {
	return string(o.buf[:o.len])
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
	eof: bool,            // it will send no more lines. It still reads
	patterns: [dynamic]string,   // what it subscribed to
}

// A unix socket accounts per message, not per byte: one send costs about 766
// bytes of kernel buffer whatever it carries. A pass goes out in one send.
MAX_OUT :: 256 * 1024

Server :: struct {
	fd:      posix.FD,
	path:    string,
	greet:   string,
	conns:   [dynamic]Conn,
	on_dump: proc(s: ^Server, fd: posix.FD, pattern: string),
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
	for &c in s.conns do close_conn(&c)
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
// (hole will :tags broker :needs connect) a dropped connection leaves nothing behind; v2 publishes the client's will.
drop :: proc(s: ^Server, i: int) {
	close_conn(&s.conns[i])
	unordered_remove(&s.conns, i)
}

@(private = "file")
close_conn :: proc(c: ^Conn) {
	posix.close(c.fd)
	delete(c.out)
	for p in c.patterns do delete(p)
	delete(c.patterns)
}

send_to :: proc(s: ^Server, fd: posix.FD, line: string) {
	for i in 0 ..< len(s.conns) {
		if s.conns[i].fd != fd do continue
		if !queue(&s.conns[i], line) do drop(s, i)
		return
	}
}

// To every connection with a pattern that matches the line's topic.
broadcast :: proc(s: ^Server, line: string) {
	topic := topic_of(line)
	i := 0
	for i < len(s.conns) {
		if subscribed(&s.conns[i], topic) && !queue(&s.conns[i], line) {
			drop(s, i)   // unordered_remove moves the last conn into i
			continue
		}
		i += 1
	}
}

@(private = "file")
subscribed :: proc(c: ^Conn, topic: string) -> bool {
	for p in c.patterns do if matches(p, topic) do return true
	return false
}

// The retained lines the pattern matches, then sync. A pattern already held
// is answered again and not stored twice.
@(private = "file")
subscribe :: proc(s: ^Server, fd: posix.FD, c: ^Conn, pattern: string) {
	held := false
	for p in c.patterns do held ||= p == pattern
	if !held {
		if len(c.patterns) == MAX_SUBS {
			send_error(s, fd, "badarg", fmt.tprintf("topic=%s", pattern),
			           "too many subscribes")
			return
		}
		append(&c.patterns, strings.clone(pattern))
	}
	if s.on_dump != nil do s.on_dump(s, fd, pattern)
	send_to(s, fd, fmt.tprintf("sync\t%s", pattern))
}

@(private = "file")
unsubscribe :: proc(c: ^Conn, pattern: string) {
	for p, i in c.patterns {
		if p != pattern do continue
		delete(p)
		unordered_remove(&c.patterns, i)
		return
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

// `about` is one key=value field naming what failed, or "".
send_error :: proc(s: ^Server, fd: posix.FD, code, about, msg: string) {
	o: Out
	begin(&o, "error")
	add(&o, "%s", code)
	if about != "" do add(&o, "%s", about)
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
}

// By fd, not by index, for the same reason srv_ready is. Sending an error can
// drop this very connection, and the next turn of the loop would then index a
// different one or run off the end.
@(private = "file")
read_conn :: proc(s: ^Server, fd: posix.FD) {
	line: [MAX_LINE]byte

	find :: proc(s: ^Server, fd: posix.FD) -> int {
		for c, i in s.conns do if c.fd == fd do return i
		return -1
	}

	for {
		i := find(s, fd)
		if i < 0 do return          // it went away while we were working

		n, what := rd_take(&s.conns[i].r, line[:])
		switch what {
		case .TooLong:
			send_error(s, fd, "toolong", "", "line over 1024 bytes")
			continue
		case .Need:
			switch rd_pull(fd, &s.conns[i].r) {
			case .Empty: return
			case .Gone:
				// EOF on the read side means it will send nothing more. It
				// does not mean it stopped reading, and a client that sends
				// one command then only listens is normal. Keep writing to
				// it until a write fails.
				s.conns[i].eof = true
				return
			case .Data: continue
			}
		case .Line:
			m, _ := parse(string(line[:n]), context.temp_allocator)
			switch m.verb {
			case "subscribe", "unsubscribe":
				if !is_pattern(m.topic) {
					send_error(s, fd, "badtopic", fmt.tprintf("topic=%s", m.topic),
					           "not a pattern")
				} else if m.verb == "subscribe" {
					subscribe(s, fd, &s.conns[i], m.topic)
				} else {
					unsubscribe(&s.conns[i], m.topic)
				}
			case "publish":
				if !is_topic(m.topic) {
					send_error(s, fd, "badtopic", fmt.tprintf("topic=%s", m.topic),
					           "not a topic")
					continue
				}
				broadcast(s, string(line[:n]))
				if s.on_cmd != nil do s.on_cmd(s, &m, fd)
			case "retain":
				// Only a claim's owner retains, so nothing that connects can
				// forge state for everything else that reads.
				// (hole connect :tags broker :needs (claims)) a client may only publish; v2 takes connect <name>, retain within that claim, publish from anyone.
				send_error(s, fd, "noconnect", "", "retain needs connect")
			case:
				send_error(s, fd, "badverb", fmt.tprintf("verb=%s", m.verb),
				           "unknown verb")
			}
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
	for c in s.conns {
		if c.fd == fd {
			read_conn(s, fd)
			return
		}
	}
}
