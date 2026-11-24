package kippsrv

PR_SET_DUMPABLE :: 4

import "core:fmt"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

@(private = "file")
the_loop: ^Loop

@(private = "file")
on_signal :: proc "c" (sig: posix.Signal) {
	if the_loop != nil do the_loop.running = false
}

main :: proc() {
	if len(os.args) > 1 do os.exit(command(os.args[1:]))

	// A crash would otherwise write every window title and SSID we hold into
	// a core file that outlives the session. This is per-process: it does
	// not touch the system setting, and a command we spawn gets its own
	// dumpable flag back at exec.
	linux.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)

	v, vok := vm_open()
	if !vok {
		fmt.eprintln("cannot start the Lua VM")
		os.exit(1)
	}
	defer vm_close(v)

	cfg, cok := config_load(v)
	if !cok do os.exit(1)
	defer config_free(&cfg)

	srv, sok := serve(cfg.socket, "version\t2\tbroker=kippsrv")
	if !sok {
		fmt.eprintfln(
`kippsrv: cannot serve %s. Either another kippsrv is already running, or the
         directory does not exist or is not writable.`, cfg.socket)
		os.exit(1)
	}
	defer stop(srv)
	srv.on_dump = store_dump
	srv.on_store = store_line
	srv.on_publish = deliver
	for spec in cfg.sources do srv.claims[spec.name] = spec.retains

	ss := Sources{vm = v}
	defer src_close(&ss)
	n := config_start(&ss, &cfg)
	cmd_bind(&ss)

	store.path = cfg.state
	defer store_close(&store)

	fmt.eprintfln("serving %s, %d sources", cfg.socket, n)

	l := Loop{srv = srv, src = &ss, store = &store}

	// Without this, SIGTERM kills the process outright: the socket file is
	// left behind, the store is not closed, and no child is signalled.
	the_loop = &l
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)   // a child that exits closes its stdin
	posix.signal(.SIGINT, on_signal)
	posix.signal(.SIGTERM, on_signal)

	run(&l)
}
