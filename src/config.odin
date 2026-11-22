// Source files.
//
// Each file is Lua in the fenced VM, so it cannot read a file or open a socket
// either. It declares its sources with source{} calls, and the functions it
// defines are the adapter that reads them.
package kippsrv

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import lua "vendor:lua/5.4"

Config :: struct {
	socket:  string,
	state:   string,
	sources: [dynamic]Src_Spec,   // every source declared, claim-only ones too
}

Src_Spec :: struct {
	name:    string,
	adapter: Adapter,    // the file that declared it
	exec:    string,     // a command for sh -c, or
	sock:    string,     // a path, or
	dbus:    []string,   // match rules, or
	system:  bool,       // the system bus instead of the session bus
	timer:   bool,       // a bare heartbeat
	throttle: Throttle,  // how often this source may reach its adapter
	watcher: bool,       // own the StatusNotifierWatcher name on this bus
	notify:  bool,       // own org.freedesktop.Notifications on this bus
	bus_name: string,    // a different name, for testing beside a live one
	every:   i64,        // ms. An exec repeats, a timer fires
	retains: []string,   // the topic patterns it may retain
	takes:   []string,   // the topic patterns of the requests it takes
}

@(private = "file")
is_var_byte :: proc(ch: byte) -> bool {
	return ch == '_' || ch >= 'A' && ch <= 'Z' || ch >= 'a' && ch <= 'z' ||
	       ch >= '0' && ch <= '9'
}

// $VAR and ~ in a path. The core does this so a script never needs the
// environment, and so nothing in Lua can read a variable it was not given.
expand :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		switch {
		case s[i] == '~' && i == 0:
			strings.write_string(&b, os.get_env("HOME", context.temp_allocator))
			i += 1
		case s[i] == '$':
			j := i + 1
			for j < len(s) && is_var_byte(s[j]) {
				j += 1
			}
			if j > i + 1 {
				strings.write_string(&b, os.get_env(s[i + 1:j], context.temp_allocator))
				i = j
			} else {
				strings.write_byte(&b, s[i])
				i += 1
			}
		case:
			strings.write_byte(&b, s[i])
			i += 1
		}
	}
	return strings.to_string(b)
}

// ------------------------------------------------------------ table reads

@(private = "file")
field_str :: proc(L: ^lua.State, key: cstring) -> (string, bool) {
	defer lua.pop(L, 1)
	if lua.getfield(L, -1, key) != c.int(lua.TSTRING) do return "", false
	return strings.clone(string(lua.tostring(L, -1))), true
}

// A path, with $VAR and ~ expanded. A command is not: sh expands it.
@(private = "file")
field_path :: proc(L: ^lua.State, key: cstring) -> (path: string, ok: bool) {
	text := field_str(L, key) or_return
	defer delete(text)
	return expand(text), true
}

@(private = "file")
field_int :: proc(L: ^lua.State, key: cstring) -> i64 {
	defer lua.pop(L, 1)
	if lua.getfield(L, -1, key) != c.int(lua.TNUMBER) do return 0
	return i64(lua.tonumber(L, -1))
}

@(private = "file")
field_bool :: proc(L: ^lua.State, key: cstring) -> bool {
	defer lua.pop(L, 1)
	lua.getfield(L, -1, key)
	return bool(lua.toboolean(L, -1))
}

// A list of strings. One string alone is a list of one.
@(private = "file")
field_list :: proc(L: ^lua.State, key: cstring) -> []string {
	defer lua.pop(L, 1)
	switch lua.getfield(L, -1, key) {
	case c.int(lua.TSTRING):
		out := make([]string, 1)
		out[0] = strings.clone(string(lua.tostring(L, -1)))
		return out
	case c.int(lua.TTABLE):
		n := int(lua.rawlen(L, -1))
		if n == 0 do return nil
		out := make([]string, n)
		for i in 1 ..= n {
			lua.rawgeti(L, -1, lua.Integer(i))
			out[i - 1] = strings.clone(string(lua.tostring(L, -1)))
			lua.pop(L, 1)
		}
		return out
	}
	return nil
}

// How often a source may reach its adapter. Absent means the defaults.
// `false` means never held back. A table overrides the keys it names.
@(private = "file")
field_throttle :: proc(L: ^lua.State) -> Throttle {
	defer lua.pop(L, 1)
	t := THROTTLE

	switch lua.getfield(L, -1, "throttle") {
	case c.int(lua.TBOOLEAN):
		if !bool(lua.toboolean(L, -1)) do return Throttle{}
	case c.int(lua.TTABLE):
		if v := field_int(L, "idle");    v > 0 do t.idle = int(v)
		if v := field_int(L, "factor");  v > 0 do t.factor = int(v)
		if v := field_int(L, "ceiling"); v > 0 do t.ceiling = v
		if v := field_int(L, "min_gap"); v > 0 do t.min_gap = v
	}
	return t
}

// The source{} table at the top of the stack.
read_spec :: proc(L: ^lua.State) -> (s: Src_Spec) {
	s.name, _ = field_str(L, "name")
	s.sock, _ = field_path(L, "sock")
	s.exec, _ = field_str(L, "exec")
	s.dbus = field_list(L, "dbus")
	s.system = field_bool(L, "system")
	s.timer = field_bool(L, "timer")
	s.throttle = field_throttle(L)
	s.watcher = field_bool(L, "watcher")
	s.notify = field_bool(L, "notify")
	s.bus_name, _ = field_str(L, "bus_name")
	s.every = field_int(L, "every")
	s.retains = field_list(L, "retains")
	s.takes = field_list(L, "takes")
	return s
}

spec_free :: proc(s: ^Src_Spec) {
	delete(s.name); delete(s.exec); delete(s.sock); delete(s.bus_name)
	for rule in s.dbus do delete(rule)
	delete(s.dbus)
	for pattern in s.retains do delete(pattern)
	delete(s.retains)
	for pattern in s.takes do delete(pattern)
	delete(s.takes)
}

// ---------------------------------------------------------------- loading

// The user's folder, then each of XDG_DATA_DIRS, most important first.
@(private = "file")
source_folders :: proc() -> []string {
	config_home := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if config_home == "" {
		config_home = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" do data_dirs = "/usr/local/share:/usr/share"

	folders := make([dynamic]string, context.temp_allocator)
	append(&folders, fmt.tprintf("%s/kippsrv/sources.d", config_home))
	for folder in strings.split(data_dirs, ":", context.temp_allocator) {
		if folder != "" do append(&folders, fmt.tprintf("%s/kippsrv/sources.d", folder))
	}
	return folders[:]
}

// Each file name once, from the first folder that holds it. Sorted, so which
// of two clashing files loads first does not depend on the file system.
@(private = "file")
source_files :: proc() -> []string {
	found := make(map[string]string, allocator = context.temp_allocator)
	for folder in source_folders() {
		entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
		if err != nil do continue
		for entry in entries {
			if entry.type == .Directory || !strings.has_suffix(entry.name, ".lua") do continue
			if entry.name not_in found do found[entry.name] = entry.fullpath
		}
	}

	names := make([dynamic]string, context.temp_allocator)
	for name in found do append(&names, name)
	slice.sort(names[:])
	paths := make([]string, len(names), context.temp_allocator)
	for name, i in names do paths[i] = found[name]
	return paths
}

config_load :: proc(v: ^Vm) -> (cfg: Config, ok: bool) {
	runtime_directory := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if runtime_directory == "" {
		fmt.eprintln("kippsrv: XDG_RUNTIME_DIR is not set, so there is nowhere to put the socket.")
		return {}, false
	}
	cfg.socket = fmt.aprintf("%s/kippsrv.sock", runtime_directory)
	cfg.state = fmt.aprintf("%s/kippsrv.state", runtime_directory)
	cfg.sources = make([dynamic]Src_Spec)
	for path in source_files() do load_file(v, &cfg, path)
	return cfg, true
}

// The first pair of patterns, one from each list, that can name one topic.
@(private = "file")
overlap :: proc(ours, theirs: []string) -> (string, string, bool) {
	for p in ours do for q in theirs {
		if matches(p, q) || matches(q, p) do return p, q, true
	}
	return "", "", false
}

// The first pattern of a source that is not one, or "". The status line
// carries a claim as one comma-joined field, so a claim holds no comma.
@(private = "file")
bad_pattern :: proc(s: Src_Spec) -> string {
	for pattern in s.retains {
		if !is_pattern(pattern) || strings.contains_rune(pattern, ',') do return pattern
	}
	for pattern in s.takes do if !is_pattern(pattern) do return pattern
	return ""
}

// A file's sources are kept whole or not at all. A name already taken, or a
// claim that overlaps another file's, refuses the file.
@(private = "file")
load_file :: proc(v: ^Vm, cfg: ^Config, path: string) {
	declared := make([dynamic]Src_Spec)
	defer delete(declared)
	v.declared = &declared
	adapter, ok := vm_load(v, path)
	v.declared = nil
	if !ok {
		for &s in declared do spec_free(&s)
		return
	}

	reason := ""
	for s, i in declared {
		if bad := bad_pattern(s); bad != "" do reason = fmt.tprintf("%q is not a pattern", bad)
		for earlier in declared[:i] {
			if earlier.name == s.name do reason = fmt.tprintf("it names %q twice", s.name)
		}
		for kept in cfg.sources {
			if kept.name == s.name {
				reason = fmt.tprintf("%s already names a source %q", v.paths[kept.adapter], s.name)
			} else if ours, theirs, clash := overlap(s.retains, kept.retains); clash {
				reason = fmt.tprintf("%s already claims %q, which overlaps %q",
				                     v.paths[kept.adapter], theirs, ours)
			}
		}
	}

	if reason != "" {
		fmt.eprintfln(
`kippsrv: %s was not loaded: %s. A source name and a topic each have one
         owner. [E-claim] See DIAGNOSTICS.md.`, path, reason)
		vm_unload(v, adapter)
		for &s in declared do spec_free(&s)
		return
	}
	for &s in declared {
		s.adapter = adapter
		append(&cfg.sources, s)
	}
}

config_free :: proc(cfg: ^Config) {
	delete(cfg.socket)
	delete(cfg.state)
	for &s in cfg.sources do spec_free(&s)
	delete(cfg.sources)
}

// Start every source declared. A file's sources share its adapter, so a seed
// and its stream share one state. A source that names nothing to run is a
// claim for a program that connects itself.
config_start :: proc(ss: ^Sources, cfg: ^Config) -> int {
	started := 0
	for spec in cfg.sources {
		a := spec.adapter
		src: ^Source
		ok: bool
		switch {
		case spec.exec != "":
			src, ok = src_exec(ss, spec.name, spec.exec, a, spec.every)
		case spec.sock != "":
			src, ok = src_sock(ss, spec.name, spec.sock, a)
		// (hole drop-sdbus :tags bus :needs (kippbus-match kippbus-tray kippbus-notify passthrough)) kippsrv opens D-Bus itself; v2 runs kippbus as an exec source.
		case len(spec.dbus) > 0 || spec.watcher || spec.notify:
			src, ok = dbus_open(ss, spec.name, spec.system, spec.dbus, a)
			if ok && spec.watcher {
				ok = watcher_start(src, spec.bus_name != "" \
					? spec.bus_name : WATCHER_NAME)
			}
			if ok && spec.notify {
				ok = notify_start(src, spec.bus_name != "" \
					? spec.bus_name : NOTIFY_NAME)
			}
		case spec.timer:
			// every defaults to 0, and a source with no period is skipped by
			// src_timeout, so the timer would simply never fire.
			if spec.every <= 0 {
				fmt.eprintfln("config: timer %q needs every > 0, skipped", spec.name)
				continue
			}
			src, ok = src_timer(ss, spec.name, spec.every, a)
		case:
			continue
		}
		if !ok {
			fmt.eprintfln("config: source %q would not start", spec.name)
			continue
		}
		src.thr = spec.throttle
		src.retains = spec.retains    // the config outlives the sources
		src.takes = spec.takes
		started += 1
	}
	return started
}
