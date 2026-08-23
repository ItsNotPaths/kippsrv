// The Lua VM and the fence around it.
//
// The fence is a fact, not a rule somebody remembers. A script gets parsed
// lines and returns lines. It never holds a descriptor, so it cannot stall
// the loop, and it never joins a line itself, so it cannot forge a fact with
// an embedded tab.
package kippsrv

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import lua "vendor:lua/5.4"

// A fact has a current value and belongs in the store. An event happened and
// does not. Only the adapter knows which, so only the adapter can say.
Emit_Kind :: enum {
	State,
	Event,
	Drop,
}

Emit :: struct {
	line: string,
	kind: Emit_Kind,
	src:  int,      // which source produced it. 0 is none
}

Vm :: struct {
	L:       ^lua.State,
	emitted: [dynamic]Emit,   // what the running script produced
}

// A loaded adapter, held by reference in the Lua registry. Zero is no
// adapter: a source can exist without one, and lua_rawgeti would index nil.
Adapter :: distinct c.int
NO_ADAPTER :: Adapter(0)

@(private = "file")
vm_of :: proc "contextless" (L: ^lua.State) -> ^Vm {
	return (^^Vm)(lua.getextraspace(L))^
}

@(private = "file")
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// ------------------------------------------------------------------- api
//
// Three calls. ideas.txt puts wweft's script surface at about forty tagged
// lines. `make tenet-api` fails if this one passes sixty.

@(private = "file")
build_and_push :: proc(L: ^lua.State, kind: Emit_Kind) -> c.int {
	n := lua.gettop(L)
	if n < 1 do return 0

	o: Out
	begin(&o, string(lua.L_checkstring(L, 1)))
	for i in 2 ..= n do add(&o, "%s", string(lua.tostring(L, i)))

	if line, ok := str(&o); ok {
		v := vm_of(L)
		append(&v.emitted, Emit{strings.clone(line, context.temp_allocator), kind, 0})
	}
	return 0
}

// @api k.emit(kind, field, ...)     a fact with a current value. Stored
@(private = "file")
l_emit :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return build_and_push(L, .State)
}

// @api k.event(kind, field, ...)    something happened. Never stored
@(private = "file")
l_event :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return build_and_push(L, .Event)
}

// @api k.drop(kind, subject, ...)   this fact no longer exists
@(private = "file")
l_drop :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return build_and_push(L, .Drop)
}

// @api k.log(...)                   diagnostics on stderr. `print` is this
@(private = "file")
l_log :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	n := lua.gettop(L)
	for i in 1 ..= n {
		fmt.eprint(lua.tostring(L, i))
		fmt.eprint(" " if i < n else "\n")
	}
	return 0
}

// @api k.parse(line) -> {kind, subj, attr} | nil
@(private = "file")
l_parse :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	n: c.size_t
	cs := lua.L_checkstring(L, 1, &n)
	m, ok := parse(string(([^]byte)(cs)[:n]), context.temp_allocator)
	if !ok {
		lua.pushnil(L)
		return 1
	}
	lua.newtable(L)

	lua.pushstring(L, cstr(m.kind))
	lua.setfield(L, -2, "kind")

	lua.newtable(L)
	for s, i in m.subj {
		lua.pushstring(L, cstr(s))
		lua.rawseti(L, -2, lua.Integer(i + 1))
	}
	lua.setfield(L, -2, "subj")

	lua.newtable(L)
	for key, val in m.attr {
		lua.pushstring(L, cstr(val))
		lua.setfield(L, -2, cstr(key))
	}
	lua.setfield(L, -2, "attr")
	return 1
}

// @api k.json(text) -> table | nil
//
// Lua has no decoder, and writing one per adapter in the wrong language is
// worse than one call here. Odin has it in the standard library.
@(private = "file")
l_json :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()

	// parse_integers keeps a whole number whole. Without it every id and
	// every pixel width arrives as a float and reaches the wire as "1920.0".
	n: c.size_t
	cs := lua.L_checkstring(L, 1, &n)
	v, err := json.parse_string(string(([^]byte)(cs)[:n]),
	                            spec = .JSON, parse_integers = true,
	                            allocator = context.temp_allocator)
	if err != .None {
		lua.pushnil(L)
		return 1
	}
	push_json(L, v)
	return 1
}

@(private = "file")
push_json :: proc(L: ^lua.State, v: json.Value) {
	switch t in v {
	case json.Null:    lua.pushnil(L)
	case json.Integer: lua.pushinteger(L, lua.Integer(t))
	case json.Float:   lua.pushnumber(L, lua.Number(t))
	case json.Boolean: lua.pushboolean(L, b32(t))
	case json.String:  lua.pushstring(L, cstr(t))
	case json.Array:
		lua.newtable(L)
		for item, i in t {
			push_json(L, item)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.newtable(L)
		for key, item in t {
			push_json(L, item)
			lua.setfield(L, -2, cstr(key))
		}
	case: lua.pushnil(L)
	}
}

// ------------------------------------------------------------------- vm

vm_open :: proc() -> (v: ^Vm, ok: bool) {
	L := lua.L_newstate()
	if L == nil do return nil, false

	v = new(Vm)
	v.L = L
	v.emitted = make([dynamic]Emit)
	(^^Vm)(lua.getextraspace(L))^ = v

	// Only these four. No io, no os, no package, no debug, no coroutine, so
	// `require` and every file and socket call simply do not exist.
	for lib in ([]struct{name: cstring, open: lua.CFunction}{
		{"_G",     lua.open_base},
		{"string", lua.open_string},
		{"table",  lua.open_table},
		{"math",   lua.open_math},
	}) {
		lua.L_requiref(L, lib.name, lib.open, 1)
		lua.pop(L, 1)
	}

	// The base library still carries three doors out of the fence.
	for name in ([]cstring{"dofile", "loadfile", "load"}) {
		lua.pushnil(L)
		lua.setglobal(L, name)
	}

	lua.pushcfunction(L, l_log)
	lua.setglobal(L, "print")

	lua.newtable(L)
	lua.pushcfunction(L, l_emit);  lua.setfield(L, -2, "emit")
	lua.pushcfunction(L, l_log);   lua.setfield(L, -2, "log")
	lua.pushcfunction(L, l_parse); lua.setfield(L, -2, "parse")
	lua.pushcfunction(L, l_json);  lua.setfield(L, -2, "json")
	lua.pushcfunction(L, l_event); lua.setfield(L, -2, "event")
	lua.pushcfunction(L, l_drop);  lua.setfield(L, -2, "drop")
	lua.setglobal(L, "k")

	return v, true
}

vm_close :: proc(v: ^Vm) {
	if v == nil do return
	lua.close(v.L)
	delete(v.emitted)
	free(v)
}

@(private = "file")
fail :: proc(v: ^Vm, what: string) -> bool {
	fmt.eprintfln("lua: %s: %s", what, lua.tostring(v.L, -1))
	lua.pop(v.L, 1)
	return false
}

// A script returns a table of functions. `feed` is the only one used today.
vm_load :: proc(v: ^Vm, path: string) -> (a: Adapter, ok: bool) {
	if lua.L_loadfile(v.L, cstr(path)) != .OK do return 0, fail(v, path)
	if lua.Status(lua.pcall(v.L, 0, 1, 0)) != .OK do return 0, fail(v, path)

	if !lua.istable(v.L, -1) {
		fmt.eprintfln("lua: %s: must return a table", path)
		lua.pop(v.L, 1)
		return 0, false
	}
	return Adapter(lua.L_ref(v.L, lua.REGISTRYINDEX)), true
}

vm_unload :: proc(v: ^Vm, a: Adapter) {
	lua.L_unref(v.L, lua.REGISTRYINDEX, c.int(a))
}

// Call one function on an adapter and take back the facts it produced. The
// returned lines live in the temp allocator and die with the loop pass.
@(private = "file")
call :: proc(v: ^Vm, a: Adapter, fn: string, arg: Maybe([]byte)) -> []Emit {
	clear(&v.emitted)
	if a == NO_ADAPTER do return nil

	lua.rawgeti(v.L, lua.REGISTRYINDEX, lua.Integer(a))
	if lua.getfield(v.L, -1, cstr(fn)) != c.int(lua.TFUNCTION) {
		lua.pop(v.L, 2)
		return nil        // an adapter need not define every function
	}

	nargs := c.int(0)
	if data, has := arg.?; has {
		// pushlstring, not pushstring: a length-prefixed frame holds NUL
		// bytes, and a cstring would stop at the first one.
		lua.pushlstring(v.L, cstring(raw_data(data)), c.size_t(len(data)))
		nargs = 1
	}
	if lua.Status(lua.pcall(v.L, nargs, 0, 0)) != .OK {
		fail(v, fn)
		lua.pop(v.L, 1)
		return nil
	}
	lua.pop(v.L, 1)
	return v.emitted[:]
}

// One line of a foreign format.
vm_feed :: proc(v: ^Vm, a: Adapter, line: string) -> []Emit {
	return call(v, a, "feed", transmute([]byte)line)
}

// One chunk of a stream that is not lines. A length-prefixed or binary
// format arrives here, and the adapter deframes it with string.unpack.
//
// Odin does not deframe. The moment the core learns a magic string or a
// header layout it has learned a foreign protocol, and Pillar 1 is gone.
// "lines or raw" is a transport noun, which the core is allowed to hold.
vm_feed_bytes :: proc(v: ^Vm, a: Adapter, data: []byte) -> []Emit {
	return call(v, a, "feed", data)
}

// The source reached the end of a batch. A format whose record spans lines
// has no terminator on the last one, so the adapter needs telling.
vm_flush :: proc(v: ^Vm, a: Adapter) -> []Emit {
	return call(v, a, "flush", nil)
}

// Any other function on the adapter, with no argument. `tick` is the one a
// timer source calls.
vm_call :: proc(v: ^Vm, a: Adapter, fn: string) -> []Emit {
	return call(v, a, fn, nil)
}

// Run a string. Used by the sandbox check, never in normal operation.
vm_eval :: proc(v: ^Vm, src: string) -> bool {
	if lua.L_loadstring(v.L, cstr(src)) != .OK do return fail(v, "eval")
	if lua.Status(lua.pcall(v.L, 0, 0, 0)) != .OK do return fail(v, "eval")
	return true
}
