// Requests, the outbound seam.
//
// Reading is the hard direction and it is why this daemon exists: five
// transports and eight formats marshalled onto one socket. Writing is not
// symmetric with it. Most of what a consumer wants to do is run a command,
// and anything can run a command. This path is for what is left over: the
// cases where kippsrv holds the only descriptor that reaches the thing.
//
// A request is a publish. It reaches every source whose `takes` matches its
// topic, as MQTT delivers to every subscriber. The core never learns what an
// action means.
package kippsrv

import "core:fmt"
import "core:sys/posix"

// What an adapter answered with. Nothing at all means nothing to do.

// Bytes for the source's own channel, exactly as they go out.
Cmd_Bytes :: struct {
	data: string,
}

// The request was wrong.
Cmd_Fail :: struct {
	code, msg: string,
}

Cmd :: union {
	Cmd_Bytes,
	Cmd_Fail,
}

// The source list. Server must not learn what a source is, so it arrives
// here rather than through the callback.
@(private = "file")
outbound: ^Sources

cmd_bind :: proc(ss: ^Sources) {
	outbound = ss
}

// A publish, from a client, a will or a source: to its subscribers, then to
// the sources that take it.
deliver :: proc(s: ^Server, line: string, m: ^Msg, fd: posix.FD) {
	broadcast(s, line)
	request(s, line, m, fd)
}

// A refusal goes back to the client that sent the request, when one did. A
// source that cannot be reached is only logged: kipp has no code for it. A
// file with no `request` speaks kipp, so its source gets the line as it is.
request :: proc(s: ^Server, line: string, m: ^Msg, fd: posix.FD) {
	if outbound == nil do return
	for src in outbound.list {
		if !any_match(src.takes, m.topic) do continue
		cmd, found := vm_request(outbound.vm, src.adapter, m, src.name)
		if !found do cmd = Cmd_Bytes{fmt.tprintf("%s\n", line)}
		switch v in cmd {
		case Cmd_Fail:
			send_error(s, fd, v.code, fmt.tprintf("topic=%s", m.topic), v.msg)
		case Cmd_Bytes:
			if !src_send(src, transmute([]byte)v.data) {
				fmt.eprintfln("kippsrv: source %q is not listening, a %s request was dropped",
				              src.name, m.topic)
			}
		}
	}
}
