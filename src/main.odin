package kippsrv

import "core:fmt"
import "core:os"
import "core:sys/posix"

SOCK_DEFAULT :: "/run/user/1000/kippsrv.sock"

// Step 1 stands in for the store: a hardcoded desktop, so the socket, the
// dump and the command path can be tested before an adapter exists.
tag_focused := 2

dump :: proc(s: ^Server, fd: posix.FD) {
	o: Out

	begin(&o, "mon");   add(&o, "eDP-1"); add(&o, "w=2256"); add(&o, "h=1504")
	add(&o, "scale=1.5")
	if line, ok := str(&o); ok do send_to(s, fd, line)

	begin(&o, "focus"); add(&o, "eDP-1")
	if line, ok := str(&o); ok do send_to(s, fd, line)

	begin(&o, "tag");   add(&o, "eDP-1"); add(&o, "%d", tag_focused)
	add(&o, "state=focused,occupied")
	if line, ok := str(&o); ok do send_to(s, fd, line)

	begin(&o, "mode");  add(&o, "normal")
	if line, ok := str(&o); ok do send_to(s, fd, line)
}

command :: proc(s: ^Server, m: ^Msg, fd: posix.FD) {
	o: Out

	if m.kind != "TAG" || len(m.subj) != 1 {
		send_error(s, fd, "badcmd", m.kind, "unknown command")
		return
	}
	begin(&o, "tag"); add(&o, "eDP-1"); add(&o, "%s", m.subj[0])
	add(&o, "state=focused,occupied")
	if line, ok := str(&o); ok do broadcast(s, line)
}

main :: proc() {
	path := os.args[1] if len(os.args) > 1 else SOCK_DEFAULT

	srv, ok := serve(path, "version\t1\tkippsrv\tproto=1")
	if !ok {
		fmt.eprintfln("cannot serve %s", path)
		os.exit(1)
	}
	defer stop(srv)

	srv.on_dump = dump
	srv.on_cmd = command
	fmt.eprintfln("serving %s", path)

	v, vok := vm_open()
	if !vok {
		fmt.eprintln("cannot start the Lua VM")
		os.exit(1)
	}
	defer vm_close(v)

	ss := Sources{vm = v}
	defer src_close(&ss)

	// Scaffolding: one source, named on the command line, so the wiring can
	// be driven before a config file exists.
	//   kippsrv <socket> exec <adapter.lua> <command...>
	//   kippsrv <socket> sock <adapter.lua> <path>
	if len(os.args) > 4 {
		a, lok := vm_load(v, os.args[3])
		if !lok do os.exit(1)

		ok2: bool
		switch os.args[2] {
		case "exec": _, ok2 = src_exec(&ss, os.args[3], os.args[4:], a)
		case "sock": _, ok2 = src_sock(&ss, os.args[3], os.args[4], a)
		case:        fmt.eprintfln("unknown source kind %q", os.args[2])
		}
		if !ok2 {
			fmt.eprintfln("cannot start the source")
			os.exit(1)
		}
	}

	l := Loop{srv = srv, src = &ss}
	run(&l)
}
