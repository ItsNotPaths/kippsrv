// `kippsrv --install` and `--uninstall`. A user install: both binaries in
// ~/.local/bin, and the shipped source files, built into this binary,
// unfurled into $XDG_DATA_HOME/kippsrv/sources.d.
package kippsrv

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

shipped_sources := #load_directory("../sources.d")

@(private = "file")
user_bin :: proc() -> string {
	return fmt.tprintf("%s/.local/bin", os.get_env("HOME", context.temp_allocator))
}

// Replaces what an earlier install put there. The folder is kippsrv's own:
// a user's files go in $XDG_CONFIG_HOME/kippsrv/sources.d.
install :: proc() -> int {
	if os.get_env("HOME", context.temp_allocator) == "" {
		fmt.eprintln("kippsrv: no $HOME, so there is nowhere to install to.")
		return 1
	}
	executable := os.read_link("/proc/self/exe", context.temp_allocator) or_else os.args[0]
	bus := fmt.tprintf("%s/kippbus", filepath.dir(executable))
	if !os.exists(bus) {
		fmt.eprintfln("kippsrv: no kippbus beside %s, so the install would be half of one.", executable)
		return 1
	}

	bin := user_bin()
	sources := fmt.tprintf("%s/kippsrv/sources.d", data_home())
	_ = os.remove_all(sources)
	for folder in ([]string{bin, sources}) {
		if err := os.make_directory_all(folder); err != nil && !os.is_dir(folder) {
			fmt.eprintfln("kippsrv: cannot create %s (%v).", folder, err)
			return 1
		}
	}

	for binary in ([][2]string{{executable, "kippsrv"}, {bus, "kippbus"}}) {
		target := fmt.tprintf("%s/%s", bin, binary[1])
		if binary[0] == target do continue
		if err := publish(target, binary[0]); err != nil {
			fmt.eprintfln("kippsrv: cannot write %s (%v).", target, err)
			return 1
		}
		fmt.printfln("  %s", target)
	}
	for adapter in shipped_sources {
		target := fmt.tprintf("%s/%s", sources, adapter.name)
		if err := os.write_entire_file(target, adapter.data); err != nil {
			fmt.eprintfln("kippsrv: cannot write %s (%v).", target, err)
			return 1
		}
	}
	fmt.printfln("  %s, %d source files", sources, len(shipped_sources))

	if !on_path(bin) do fmt.printfln("  %s is not on your PATH. Add it:\n    export PATH=\"%s:$PATH\"", bin, bin)
	fmt.println("installed. To change a source file, copy it into ~/.config/kippsrv/sources.d and edit the copy.")
	return 0
}

// Every file of kippsrv it can find: both binaries, the source files, the
// user's own source files, and the socket and state file. That includes a
// system install under each of XDG_DATA_DIRS, which needs the rights to
// remove it.
uninstall :: proc() -> int {
	socket := fmt.tprintf("%s/kippsrv.sock", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator))
	if in_use(socket) {
		fmt.eprintln("kippsrv: kippsrv is running. Stop it first.")
		return 1
	}

	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, fmt.tprintf("%s/kippsrv", user_bin()), fmt.tprintf("%s/kippbus", user_bin()))
	append(&paths, fmt.tprintf("%s/kippsrv", data_home()), fmt.tprintf("%s/kippsrv", config_home()))
	append(&paths, socket, fmt.tprintf("%s/kippsrv.state", filepath.dir(socket)))
	for folder in data_dirs() {
		if !strings.has_suffix(folder, "/share") do continue
		prefix := strings.trim_suffix(folder, "/share")
		append(&paths, fmt.tprintf("%s/kippsrv", folder))
		append(&paths, fmt.tprintf("%s/bin/kippsrv", prefix), fmt.tprintf("%s/bin/kippbus", prefix))
	}

	removed, failed := 0, 0
	for path in paths {
		if !os.exists(path) do continue
		if err := os.remove_all(path); err != nil {
			fmt.eprintfln("  cannot remove %s (%v)", path, err)
			failed += 1
			continue
		}
		fmt.printfln("  removed %s", path)
		removed += 1
	}
	switch {
	case failed > 0:
		fmt.eprintln("uninstall left files it had no rights to remove. A system install needs sudo.")
		return 1
	case removed == 0:
		fmt.println("nothing of kippsrv is here to remove.")
	case:
		fmt.println("uninstalled.")
	}
	return 0
}

// Staged beside the target and renamed over it, so a running copy keeps its
// old file.
@(private = "file")
publish :: proc(target, source: string) -> os.Error {
	stage := fmt.tprintf("%s.tmp", target)
	_ = os.remove(stage)
	os.copy_file(stage, source) or_return
	if err := os.rename(stage, target); err != nil {
		_ = os.remove(stage)
		return err
	}
	return nil
}

@(private = "file")
on_path :: proc(folder: string) -> bool {
	rest := os.get_env("PATH", context.temp_allocator)
	for entry in strings.split_iterator(&rest, ":") do if entry == folder do return true
	return false
}
