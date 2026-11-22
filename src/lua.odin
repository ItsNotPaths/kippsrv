// The Lua VM and the fence around it.
//
// A script gets parsed lines and returns fields. It never holds a descriptor
// and never joins a line, so it cannot reach the system or forge a fact with
// an embedded tab.
package kippsrv

import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import lua "vendor:lua/5.4"

Emit :: struct {
	line: string,
	src:  int,      // which source produced it. 0 is none
}

Vm :: struct {
	L:       ^lua.State,
	emitted: [dynamic]Emit,   // what the running script produced
	budget:  int,             // instruction slices left in the running call
	mem:     ^Mem,            // what the script has allocated
	paths:   map[Adapter]string,   // which file each adapter came from
	running: Adapter,              // whose call we are inside, for diagnostics
	declared: ^[dynamic]Src_Spec,  // where source{} calls go while a file loads, or nil
}

// The sandbox does not stop `while true do end`. This does.
STEPS   :: 10_000     // instructions between hook calls
SLICES  :: 200        // slices allowed per call, so about 2M instructions

// Nor does the step hook stop `string.rep("x", 1e9)`: one C call, and a count
// hook only fires between instructions. Refusing an allocation raises an
// ordinary Lua memory error, which pcall catches.
MEM_CAP :: 64 << 20

Mem :: struct {
	used: int,
}

@(private = "file")
lua_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	m := (^Mem)(ud)

	if nsize == 0 {
		// osize is a size only when ptr is real. For a fresh allocation it
		// encodes what kind of object Lua wants.
		if ptr != nil {
			m.used -= int(osize)
			libc.free(ptr)
		}
		return nil
	}

	want := m.used + int(nsize) - (ptr != nil ? int(osize) : 0)
	if want > MEM_CAP do return nil

	p := libc.realloc(ptr, nsize)
	if p != nil do m.used = want
	return p
}

// A loaded adapter, held by reference in the Lua registry. Zero is no
// adapter: a source can exist without one, and lua_rawgeti would index nil.
Adapter :: distinct c.int
NO_ADAPTER :: Adapter(0)

@(private = "file")
on_step :: proc "c" (L: ^lua.State, ar: ^lua.Debug) {
	v := vm_of(L)
	v.budget -= 1
	if v.budget <= 0 do lua.L_error(L, "script ran too long and was stopped")
}

@(private = "file")
vm_of :: proc "contextless" (L: ^lua.State) -> ^Vm {
	return (^^Vm)(lua.getextraspace(L))^
}

// ------------------------------------------------------------------- api

// Build one line from its fields and keep it. Only kipp reaches the socket: a
// field cannot carry a tab or a newline, and a bad topic or field would make a
// line no reader can take apart.
@(private = "file")
keep :: proc(v: ^Vm, verb, topic: string, payload: []string) {
	bad := "" if is_topic(topic) else topic
	for field in payload do if !is_field(field) do bad = field
	if bad != "" {
		fmt.eprintfln(
`kippsrv: %s produced a line that is not kipp and it was dropped. This is a
         bug in that adapter file, not in your configuration.
         [E-word] %q is not a topic whose kind is a word of lowercase
         letters, digits and underscores, or not a key=value field whose key
         is such a word. See DIAGNOSTICS.md.`,
			v.paths[v.running], bad)
		return
	}

	o: Out
	begin(&o, verb)
	add(&o, "%s", topic)
	for field in payload do add(&o, "%s", field)
	line, ok := str(&o)
	if !ok {
		// Silently losing a line leaves an adapter author nothing to go on.
		fmt.eprintfln(
`kippsrv: %s produced a %q line longer than %d bytes and it was dropped. This
         is a bug in that adapter file, not in your configuration.
         [E-toolong] See DIAGNOSTICS.md.`,
			v.paths[v.running], topic, MAX_LINE)
		return
	}
	append(&v.emitted, Emit{strings.clone(line, context.temp_allocator), 0})
}

@(private = "file")
build_and_push :: proc(L: ^lua.State, verb: string) -> c.int {
	topic := string(lua.L_checkstring(L, 1))
	payload := make([dynamic]string, context.temp_allocator)
	for i in 2 ..= lua.gettop(L) do append(&payload, string(lua.tostring(L, i)))
	keep(vm_of(L), verb, topic, payload[:])
	return 0
}

// @api k.retain(topic, key=value, ...)   a value. Stored. No payload deletes it
@(private = "file")
l_retain :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return build_and_push(L, "retain")
}

// @api k.publish(topic, key=value, ...)  an event. Never stored
@(private = "file")
l_publish :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	return build_and_push(L, "publish")
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

// One parsed line as a table. `k.parse` returns this, and a command arrives
// as it, so an adapter reads both the same way.
@(private = "file")
push_msg :: proc(L: ^lua.State, m: ^Msg) {
	lua.newtable(L)

	lua.pushstring(L, cstr(m.verb))
	lua.setfield(L, -2, "verb")

	lua.pushstring(L, cstr(m.topic))
	lua.setfield(L, -2, "topic")

	lua.newtable(L)
	for key, val in m.payload {
		lua.pushstring(L, cstr(val))
		lua.setfield(L, -2, cstr(key))
	}
	lua.setfield(L, -2, "payload")
}

// @api k.parse(line) -> {verb, topic, payload} | nil
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
	push_msg(L, &m)
	return 1
}

// @api source{name=..., exec=..., retains=...}   declare a source of this file
@(private = "file")
l_source :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	if !lua.istable(L, 1) do lua.L_error(L, "source{} takes a table")
	lua.settop(L, 1)

	s := read_spec(L)
	v := vm_of(L)
	if v.declared != nil && s.name != "" {
		append(v.declared, s)
		return 0
	}
	spec_free(&s)
	if v.declared != nil do lua.L_error(L, "source{} needs a name")
	return 0
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

JSON_MAX_DEPTH :: 32

// A payload comes from a compositor or the bus, so its shape is not ours to
// trust. Without a bound this recurses per level until the C stack goes.
@(private = "file")
push_json :: proc(L: ^lua.State, v: json.Value, depth := 0) {
	if depth > JSON_MAX_DEPTH || lua.checkstack(L, 4) == 0 {
		lua.pushnil(L)
		return
	}
	switch t in v {
	case json.Null:    lua.pushnil(L)
	case json.Integer: lua.pushinteger(L, lua.Integer(t))
	case json.Float:   lua.pushnumber(L, lua.Number(t))
	case json.Boolean: lua.pushboolean(L, b32(t))
	case json.String:  lua.pushstring(L, cstr(t))
	case json.Array:
		lua.newtable(L)
		for item, i in t {
			push_json(L, item, depth + 1)
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
	case json.Object:
		lua.newtable(L)
		for key, item in t {
			push_json(L, item, depth + 1)
			lua.setfield(L, -2, cstr(key))
		}
	case: lua.pushnil(L)
	}
}

// ------------------------------------------------------------------- vm

vm_open :: proc() -> (v: ^Vm, ok: bool) {
	mem := new(Mem)
	L := lua.newstate(lua_alloc, mem)
	if L == nil {
		free(mem)
		return nil, false
	}

	v = new(Vm)
	v.L = L
	v.mem = mem
	v.emitted = make([dynamic]Emit)
	v.paths = make(map[Adapter]string)
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

	lua.sethook(L, on_step, lua.MASKCOUNT, STEPS)

	lua.newtable(L)
	lua.pushcfunction(L, l_retain);  lua.setfield(L, -2, "retain")
	lua.pushcfunction(L, l_publish); lua.setfield(L, -2, "publish")
	lua.pushcfunction(L, l_log);     lua.setfield(L, -2, "log")
	lua.pushcfunction(L, l_parse);   lua.setfield(L, -2, "parse")
	lua.pushcfunction(L, l_json);    lua.setfield(L, -2, "json")
	lua.setglobal(L, "k")

	lua.pushcfunction(L, l_source)
	lua.setglobal(L, "source")

	return v, true
}

vm_close :: proc(v: ^Vm) {
	if v == nil do return
	lua.close(v.L)
	delete(v.emitted)
	for _, p in v.paths do delete(p)
	delete(v.paths)
	free(v.mem)
	free(v)
}

@(private = "file")
fail :: proc(v: ^Vm, what: string) -> bool {
	fmt.eprintfln("lua: %s: %s", what, lua.tostring(v.L, -1))
	lua.pop(v.L, 1)
	return false
}

// A file runs in its own globals, so its `feed` is not another file's. Reads
// fall through to the shared ones, where `k` and `source` live. Those globals
// are the adapter.
vm_load :: proc(v: ^Vm, path: string) -> (a: Adapter, ok: bool) {
	v.budget = SLICES
	if lua.L_loadfile(v.L, cstr(path)) != .OK do return 0, fail(v, path)

	lua.newtable(v.L)                  // the file's globals
	lua.newtable(v.L)
	lua.pushglobaltable(v.L)
	lua.setfield(v.L, -2, "__index")
	lua.setmetatable(v.L, -2)
	lua.pushvalue(v.L, -1)
	lua.setupvalue(v.L, -3, 1)         // the chunk's _ENV
	lua.insert(v.L, -2)                // the globals under the chunk

	if lua.Status(lua.pcall(v.L, 0, 0, 0)) != .OK {
		fail(v, path)
		lua.pop(v.L, 1)
		return 0, false
	}
	ref := Adapter(lua.L_ref(v.L, lua.REGISTRYINDEX))
	v.paths[ref] = strings.clone(path)
	return ref, true
}

vm_unload :: proc(v: ^Vm, a: Adapter) {
	lua.L_unref(v.L, lua.REGISTRYINDEX, c.int(a))
	_, path := delete_key(&v.paths, a)   // the ref is reused by the next load
	delete(path)
}

// Call one function on an adapter and take back the facts it produced. The
// returned lines live in the temp allocator and die with the loop pass.
@(private = "file")
call :: proc(v: ^Vm, a: Adapter, fn: string, arg: Maybe([]byte)) -> (out: []Emit, found: bool) {
	clear(&v.emitted)
	if a == NO_ADAPTER do return nil, false

	lua.rawgeti(v.L, lua.REGISTRYINDEX, lua.Integer(a))
	if lua.getfield(v.L, -1, cstr(fn)) != c.int(lua.TFUNCTION) {
		lua.pop(v.L, 2)
		return nil, false        // an adapter need not define every function
	}

	nargs := c.int(0)
	if data, has := arg.?; has {
		// pushlstring, not pushstring: a line can hold a NUL byte, and a
		// cstring would stop at the first one.
		lua.pushlstring(v.L, cstring(raw_data(data)), c.size_t(len(data)))
		nargs = 1
	}
	v.budget = SLICES
	v.running = a
	if lua.Status(lua.pcall(v.L, nargs, 0, 0)) != .OK {
		fail(v, fn)
		lua.pop(v.L, 1)
		return nil, true
	}
	lua.pop(v.L, 1)
	return v.emitted[:], true
}

// A file with no feed is for a program that prints kipp. Its retain and
// publish lines pass through, and the rest of its session is not ours.
@(private = "file")
pass :: proc(v: ^Vm, a: Adapter, line: string) -> []Emit {
	clear(&v.emitted)
	v.running = a
	fields := strings.split(line, "\t", context.temp_allocator)
	if len(fields) >= 2 && (fields[0] == "retain" || fields[0] == "publish") {
		keep(v, fields[0], fields[1], fields[2:])
	}
	return v.emitted[:]
}

// One line of a foreign format.
vm_feed :: proc(v: ^Vm, a: Adapter, line: string) -> []Emit {
	out, found := call(v, a, "feed", transmute([]byte)line)
	return out if found else pass(v, a, line)
}

// The source reached the end of a batch. A format whose record spans lines
// has no terminator on the last one, so the adapter needs telling.
vm_flush :: proc(v: ^Vm, a: Adapter) -> []Emit {
	out, _ := call(v, a, "flush", nil)
	return out
}

// Any other function on the adapter, with no argument. `tick` is the one a
// timer source calls.
vm_call :: proc(v: ^Vm, a: Adapter, fn: string) -> []Emit {
	out, _ := call(v, a, fn, nil)
	return out
}

// ------------------------------------------------------------- commands

@(private = "file")
str_at :: proc(L: ^lua.State, i: c.int) -> string {
	n: c.size_t
	cs := lua.tolstring(L, i, &n)
	if cs == nil do return ""
	return strings.clone(string(([^]byte)(cs)[:n]), context.temp_allocator)
}

// One request to one adapter. It answers with bytes for its own source, a
// refusal, or nothing. found is false when the file defines no `request`.
//
// The fence holds. The script hands back bytes and never sends them, and the
// descriptor the answer travels down is never in its reach.
//
// The source's name goes along, because one adapter file can serve several
// sources.
vm_request :: proc(v: ^Vm, a: Adapter, m: ^Msg, source: string) -> (cmd: Cmd, found: bool) {
	if a == NO_ADAPTER do return nil, false
	clear(&v.emitted)

	lua.rawgeti(v.L, lua.REGISTRYINDEX, lua.Integer(a))
	if lua.getfield(v.L, -1, "request") != c.int(lua.TFUNCTION) {
		lua.pop(v.L, 2)
		return nil, false
	}
	push_msg(v.L, m)
	lua.pushstring(v.L, cstr(source))

	v.budget = SLICES
	v.running = a
	if lua.Status(lua.pcall(v.L, 2, 3, 0)) != .OK {
		fail(v, "request")
		lua.pop(v.L, 1)
		return nil, true
	}
	defer lua.pop(v.L, 4)   // three results and the adapter table

	// A request produces no facts. The state that follows the action shows
	// what it did, which is the rule in kipp's SPEC.md, and an adapter that
	// emits here would be guessing at it.
	if len(v.emitted) > 0 {
		fmt.eprintfln(
`kippsrv: %s emitted %d facts while taking a %q request, and they were
         dropped. This is a bug in that adapter file.
         [E-cmdemit] See DIAGNOSTICS.md.`, v.paths[a], len(v.emitted), m.topic)
		clear(&v.emitted)
	}

	top := lua.gettop(v.L)
	if lua.type(v.L, top - 2) == .STRING do return Cmd_Bytes{str_at(v.L, top - 2)}, true

	// Nothing, and a reason: the request was wrong.
	if lua.type(v.L, top - 1) == .STRING {
		return Cmd_Fail{str_at(v.L, top - 1), str_at(v.L, top)}, true
	}
	return nil, true
}

// Run a string. Used by the sandbox check, never in normal operation.
vm_eval :: proc(v: ^Vm, src: string) -> bool {
	v.budget = SLICES
	if lua.L_loadstring(v.L, cstr(src)) != .OK do return fail(v, "eval")
	if lua.Status(lua.pcall(v.L, 0, 0, 0)) != .OK do return fail(v, "eval")
	return true
}
