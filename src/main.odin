package kippsrv

import "core:fmt"
import "core:os"
import "core:sys/posix"

// The dump is the store, in the order facts were first seen.
store: Store

dump :: proc(s: ^Server, fd: posix.FD) {
	lines := make([dynamic]string, context.temp_allocator)
	store_each(&store, &lines)
	for line in lines do send_to(s, fd, line)
}

// Nothing takes commands yet. The outbound half is an adapter function that
// turns a command into bytes for its source. Until then, say so.
command :: proc(s: ^Server, m: ^Msg, fd: posix.FD) {
	send_error(s, fd, "badcmd", m.kind, "no adapter takes commands yet")
}

main :: proc() {
	v, vok := vm_open()
	if !vok {
		fmt.eprintln("cannot start the Lua VM")
		os.exit(1)
	}
	defer vm_close(v)

	path := len(os.args) > 1 ? os.args[1] : "config.lua"
	cfg, cok := config_load(v, path)
	if !cok do os.exit(1)
	defer config_free(&cfg)

	if cfg.socket == "" {
		fmt.eprintfln("config: %s names no socket", path)
		os.exit(1)
	}

	srv, sok := serve(cfg.socket, "version\t1\tkippsrv\tproto=1")
	if !sok {
		fmt.eprintfln("cannot serve %s", cfg.socket)
		os.exit(1)
	}
	defer stop(srv)
	srv.on_dump = dump
	srv.on_cmd = command

	ss := Sources{vm = v}
	defer src_close(&ss)
	n := config_start(v, &ss, &cfg)

	store.path = cfg.state
	defer store_close(&store)

	fmt.eprintfln("serving %s, %d sources", cfg.socket, n)

	l := Loop{srv = srv, src = &ss, store = &store}
	run(&l)
}
