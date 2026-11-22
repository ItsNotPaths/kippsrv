// The command line. With no arguments kippsrv runs; with one it answers and
// exits.
package kippsrv

import "core:fmt"
import "core:strings"

// Stamped by `build.sh --version <tag>`.
VERSION :: #config(VERSION, "dev")

@(private = "file")
USAGE :: `usage: kippsrv [command]

  (none)            run: serve the socket and every source file
  --check           load the source files, list each source and its claim, and exit
  --install         install kippsrv and kippbus in ~/.local/bin, and the shipped
                    source files in ~/.local/share/kippsrv/sources.d
  --uninstall       remove every file of kippsrv: both binaries, the shipped source
                    files, yours in ~/.config/kippsrv, and the socket and state file
  readme            print the README
  howto             print the HOWTO
  howto <word>...   print the parts of the HOWTO about those words
  --version         the version this binary was built as
  --help            this
`

// The exit code.
command :: proc(arguments: []string) -> int {
	switch arguments[0] {
	case "--help", "-h", "help":
		fmt.print(USAGE)
		return 0
	case "--check":
		return check()
	case "--install":
		return install()
	case "--uninstall":
		return uninstall()
	case "--version":
		fmt.println(VERSION)
		return 0
	case "readme":
		fmt.print(README)
		return 0
	case "howto":
		if len(arguments) == 1 {
			fmt.print(howto_text())
			return 0
		}
		return howto(arguments[1:])
	}
	fmt.eprint(USAGE)
	return 2
}

@(private = "file")
howto :: proc(query: []string) -> int {
	found := howto_find(query)
	if len(found) == 0 {
		fmt.eprintfln("kippsrv: nothing in the HOWTO about %q. `kippsrv howto` prints all of it.",
		              strings.join(query, " ", context.temp_allocator))
		return 1
	}
	for snippet, index in found {
		if index > 0 do fmt.println()
		fmt.printfln("# %s\n\n%s", snippet.heading, snippet.text)
	}
	return 0
}

// The source files as a start would load them, and nothing served. Refused
// files have already said why on stderr.
@(private = "file")
check :: proc() -> int {
	v, opened := vm_open()
	if !opened {
		fmt.eprintln("cannot start the Lua VM")
		return 1
	}
	defer vm_close(v)
	cfg, loaded := config_load(v)
	if !loaded do return 1
	defer config_free(&cfg)

	file := ""
	for spec in cfg.sources {
		if path := v.paths[spec.adapter]; path != file {
			fmt.println(path)
			file = path
		}
		fmt.printfln("  %s", describe(spec))
	}
	fmt.printfln("%d sources, %d files refused", len(cfg.sources), cfg.refused)
	return 1 if cfg.refused > 0 else 0
}

@(private = "file")
describe :: proc(spec: Src_Spec) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, spec.name)
	switch {
	case spec.exec != "": fmt.sbprintf(&builder, "  exec %q", spec.exec)
	case spec.sock != "": fmt.sbprintf(&builder, "  sock %s", spec.sock)
	case spec.timer:      strings.write_string(&builder, "  timer")
	case:                 strings.write_string(&builder, "  claim only")
	}
	if spec.every > 0 do fmt.sbprintf(&builder, "  every %d ms", spec.every)
	if len(spec.retains) > 0 do fmt.sbprintf(&builder, "  retains %s", strings.join(spec.retains, ",", context.temp_allocator))
	if len(spec.takes) > 0 do fmt.sbprintf(&builder, "  takes %s", strings.join(spec.takes, ",", context.temp_allocator))
	return strings.to_string(builder)
}
