// The outbound seam.
//
// Reading is the hard direction and it is why this daemon exists: five
// transports and eight formats marshalled onto one socket. Writing is not
// symmetric with it. Most of what a consumer wants to do is run a command,
// and anything can run a command. This path is for what is left over: the
// cases where kippsrv holds the only descriptor that reaches the thing.
//
// A command is offered to each source in configuration order, and the first
// adapter that answers owns it. The core never learns what a verb means.
package kippsrv

import "core:fmt"
import "core:sys/posix"

// What an adapter answered with. Nothing at all means the command was not
// its, and the next source is asked.

// Bytes for the source's own channel, exactly as they go out.
Cmd_Bytes :: struct {
	data: string,
}

// A method call on the bus the source already holds. Arguments cross as
// text and `sig` says what each one is, because D-Bus is typed and Lua has
// one number type.
Cmd_Call :: struct {
	dest, path, iface, member, sig: string,
	args:                           []string,
}

// The verb was this adapter's and something about it was wrong.
Cmd_Fail :: struct {
	code, msg: string,
}

Cmd :: union {
	Cmd_Bytes,
	Cmd_Call,
	Cmd_Fail,
}

// The source list. Server must not learn what a source is, so it arrives
// here rather than through the callback.
@(private = "file")
outbound: ^Sources

cmd_bind :: proc(ss: ^Sources) {
	outbound = ss
}

// SPEC.md names four. An adapter that invents a fifth would put a line on the
// wire that no consumer can read, so the wire wins.
@(private = "file")
known :: proc(code: string) -> string {
	switch code {
	case "badcmd", "badarg", "nosrc", "toolong":
		return code
	}
	return "badarg"
}

command :: proc(s: ^Server, m: ^Msg, fd: posix.FD) {
	if outbound == nil {
		send_error(s, fd, "nosrc", m.kind, "nothing is configured")
		return
	}

	for src in outbound.list {
		what := vm_command(outbound.vm, src.adapter, m)
		if what == nil do continue

		switch v in what {
		case Cmd_Fail:
			send_error(s, fd, known(v.code), m.kind, v.msg)
		case Cmd_Bytes:
			if !src_send(src, transmute([]byte)v.data) {
				send_error(s, fd, "nosrc", m.kind,
				           fmt.tprintf("%s is not listening", src.name))
			}
		case Cmd_Call:
			if !dbus_call(src, v) {
				send_error(s, fd, "nosrc", m.kind,
				           fmt.tprintf("%s refused the call", src.name))
			}
		}
		return
	}
	send_error(s, fd, "badcmd", m.kind, "no adapter takes this command")
}
