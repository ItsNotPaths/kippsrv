// Configuration is a language, not a file format.
//
// The file returns a table. It runs in the same fenced VM as an adapter, so it
// cannot read a file or open a socket either. Everything it can express is
// here, and there is no key that means "run this".
package kippsrv

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import lua "vendor:lua/5.4"

Config :: struct {
	socket:  string,
	state:   string,
	sources: [dynamic]Src_Spec,
}

Src_Spec :: struct {
	name:    string,
	adapter: string,
	exec:    []string,   // a command, or
	sock:    string,     // a path, or
	dbus:    []string,   // match rules, or
	system:  bool,       // the system bus instead of the session bus
	timer:   bool,       // a bare heartbeat
	throttle: Throttle,  // how often this source may reach its adapter
	watcher: bool,       // own the StatusNotifierWatcher name on this bus
	notify:  bool,       // own org.freedesktop.Notifications on this bus
	bus_name: string,    // a different name, for testing beside a live one
	every:   i64,        // ms. An exec repeats, a timer fires
	cmd:     string,     // where a command goes back out, when it is not `sock`
	framing: Framing,
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
	return expand(string(lua.tostring(L, -1))), true
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

@(private = "file")
field_list :: proc(L: ^lua.State, key: cstring) -> []string {
	defer lua.pop(L, 1)
	if lua.getfield(L, -1, key) != c.int(lua.TTABLE) do return nil

	n := int(lua.rawlen(L, -1))
	if n == 0 do return nil
	out := make([]string, n)
	for i in 1 ..= n {
		lua.rawgeti(L, -1, lua.Integer(i))
		out[i - 1] = expand(string(lua.tostring(L, -1)))
		lua.pop(L, 1)
	}
	return out
}

// The framing a source declares. Absent means lines, which is nearly always
// right. A binary source says so.
@(private = "file")
field_framing :: proc(L: ^lua.State) -> Framing {
	defer lua.pop(L, 1)
	if lua.getfield(L, -1, "framing") != c.int(lua.TTABLE) do return Lines{}

	kind, _ := field_str(L, "kind")
	switch kind {
	case "raw":
		return Raw{}
	case "prefix":
		p := Prefix{
			header = int(field_int(L, "header")),
			at     = int(field_int(L, "at")),
			width  = int(field_int(L, "width")),
			le     = field_bool(L, "le"),
		}
		// A header that holds no length field would frame nothing and be
		// asked for again forever.
		if p.header <= 0 || p.width <= 0 || p.at < 0 || p.at + p.width > p.header {
			fmt.eprintfln("config: prefix framing needs 0 <= at, 0 < width, " +
			              "at+width <= header. Got header=%d at=%d width=%d. " +
			              "Falling back to lines.", p.header, p.at, p.width)
			return Lines{}
		}
		return p
	}
	return Lines{}
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

// ---------------------------------------------------------------- loading

config_load :: proc(v: ^Vm, path: string) -> (cfg: Config, ok: bool) {
	L := v.L
	if lua.L_loadfile(L, strings.clone_to_cstring(path, context.temp_allocator)) != .OK ||
	   lua.Status(lua.pcall(L, 0, 1, 0)) != .OK {
		fmt.eprintfln("config: %s: %s", path, lua.tostring(L, -1))
		lua.pop(L, 1)
		return {}, false
	}
	defer lua.pop(L, 1)

	if !lua.istable(L, -1) {
		fmt.eprintfln("config: %s must return a table", path)
		return {}, false
	}

	cfg.socket, _ = field_str(L, "socket")
	cfg.state, _ = field_str(L, "state")
	cfg.sources = make([dynamic]Src_Spec)

	if lua.getfield(L, -1, "sources") != c.int(lua.TTABLE) {
		lua.pop(L, 1)
		return cfg, true            // a socket and nothing to read is legal
	}
	defer lua.pop(L, 1)

	for i in 1 ..= int(lua.rawlen(L, -1)) {
		lua.rawgeti(L, -1, lua.Integer(i))
		defer lua.pop(L, 1)
		if !lua.istable(L, -1) do continue

		s: Src_Spec
		s.name, _ = field_str(L, "name")
		s.adapter, _ = field_str(L, "adapter")
		s.sock, _ = field_str(L, "sock")
		s.exec = field_list(L, "exec")
		s.dbus = field_list(L, "dbus")
		s.system = field_bool(L, "system")
		s.timer = field_bool(L, "timer")
		s.throttle = field_throttle(L)
		s.watcher = field_bool(L, "watcher")
		s.notify = field_bool(L, "notify")
		s.bus_name, _ = field_str(L, "bus_name")
		s.every = field_int(L, "every")
		s.cmd, _ = field_str(L, "cmd")
		s.framing = field_framing(L)

		if s.adapter == "" && !s.watcher && !s.notify {
			fmt.eprintfln("config: source %d has no adapter, skipped", i)
			continue
		}
		if s.name == "" do s.name = s.adapter
		append(&cfg.sources, s)
	}
	return cfg, true
}

config_free :: proc(cfg: ^Config) {
	delete(cfg.socket)
	delete(cfg.state)
	for s in cfg.sources {
		delete(s.name); delete(s.adapter); delete(s.sock); delete(s.bus_name)
		delete(s.cmd)
		for a in s.exec do delete(a)
		delete(s.exec)
		for a in s.dbus do delete(a)
		delete(s.dbus)
	}
	delete(cfg.sources)
}

// Start every source the configuration names. An adapter file is loaded once
// however many sources name it, so a seed and its stream share one state.
config_start :: proc(v: ^Vm, ss: ^Sources, cfg: ^Config) -> int {
	loaded := make(map[string]Adapter, allocator = context.temp_allocator)
	started := 0

	for spec in cfg.sources {
		a: Adapter
		seen := true
		if spec.adapter != "" do a, seen = loaded[spec.adapter]
		if !seen {
			ok: bool
			a, ok = vm_load(v, spec.adapter)
			if !ok {
				fmt.eprintfln("config: %s did not load, source %q skipped",
				              spec.adapter, spec.name)
				continue
			}
			loaded[spec.adapter] = a
		}

		src: ^Source
		ok: bool
		switch {
		case len(spec.exec) > 0:
			src, ok = src_exec(ss, spec.name, spec.exec, a, spec.framing, spec.every)
		case spec.sock != "":
			src, ok = src_sock(ss, spec.name, spec.sock, a, spec.framing)
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
			fmt.eprintfln("config: source %q names no exec, sock or timer", spec.name)
			continue
		}
		if !ok {
			fmt.eprintfln("config: source %q would not start", spec.name)
			continue
		}
		src.thr = spec.throttle
		src.cmd_path = strings.clone(spec.cmd)
		started += 1
	}
	return started
}
