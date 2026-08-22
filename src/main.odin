package kippsrv

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

SOCK_DEFAULT :: "/run/user/1000/kippsrv.sock"

// The dump is the store, in the order facts were first seen.
store: Store

dump :: proc(s: ^Server, fd: posix.FD) {
	lines := make([dynamic]string, context.temp_allocator)
	store_each(&store, &lines)
	for line in lines do send_to(s, fd, line)
}

// Scaffolding until an adapter takes commands. See the outbound half in the
// README.
command :: proc(s: ^Server, m: ^Msg, fd: posix.FD) {
	o: Out

	if m.kind != "TAG" || len(m.subj) != 1 {
		send_error(s, fd, "badcmd", m.kind, "unknown command")
		return
	}
	begin(&o, "tag"); add(&o, "eDP-1"); add(&o, "%s", m.subj[0])
	add(&o, "state=focused,occupied")
	if line, ok := str(&o); ok {
		if out := store_apply(&store, Emit{line, .State}); out != "" {
			broadcast(s, out)
		}
	}
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

	store.path = strings.concatenate({path, ".state"})
	defer store_close(&store)
	defer delete(store.path)

	l := Loop{srv = srv, src = &ss, store = &store}
	run(&l)
}
