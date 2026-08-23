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

// A fact has a current value and belongs in the store. An event does not.
// Only the adapter knows which.
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
	budget:  int,             // instruction slices left in the running call
	mem:     ^Mem,            // what the script has allocated
	paths:   map[Adapter]string,   // which file each adapter came from
	running: Adapter,              // whose call we are inside, for diagnostics
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

// Temp-allocated, so it dies with the loop pass like everything else.
cstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

// ------------------------------------------------------------------- api

@(private = "file")
build_and_push :: proc(L: ^lua.State, kind: Emit_Kind) -> c.int {
	n := lua.gettop(L)
	if n < 1 do return 0

	o: Out
	begin(&o, string(lua.L_checkstring(L, 1)))
	for i in 2 ..= n do add(&o, "%s", string(lua.tostring(L, i)))

	v := vm_of(L)

	// A stored fact needs a subject: that is its identity. A field holding
	// '=' reads as the first attribute, so a subject that holds one leaves
	// the fact keyed on its kind alone, colliding with every other fact of
	// that kind. An event is never stored and needs no subject.
	if kind != .Event && n >= 2 {
		m, good := parse(line_of(&o), context.temp_allocator)
		if good && len(m.subj) == 0 {
			culprit := ""
			for i in 2 ..= n {
				f := string(lua.tostring(L, i))
				if strings.contains(f, "=") {
					culprit = f
					break
				}
			}
			fmt.eprintfln(
`kippsrv: %s produced an unusable %q fact and it was dropped.
         Something will be missing from your desktop. This is a bug in that
         adapter file, not in your configuration. Please report it to whoever
         maintains it, and quote this message.
         [E-subject] the field %q holds '=', so it read as an attribute and
         the fact kept no subject. See DIAGNOSTICS.md.`,
				v.paths[v.running], m.kind, culprit)
			return 0
		}
	}

	line, ok := str(&o)
	if !ok {
		// Silently losing a fact leaves an adapter author nothing to go on.
		fmt.eprintfln(
`kippsrv: %s produced a %q fact longer than %d bytes and it was dropped. This
         is a bug in that adapter file, not in your configuration.
         [E-toolong] See DIAGNOSTICS.md.`,
			v.paths[v.running], string(lua.L_checkstring(L, 1)), MAX_LINE)
		return 0
	}
	append(&v.emitted, Emit{strings.clone(line, context.temp_allocator), kind, 0})
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

// One parsed line as a table. `k.parse` returns this, and a command arrives
// as it, so an adapter reads both the same way.
@(private = "file")
push_msg :: proc(L: ^lua.State, m: ^Msg) {
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
	push_msg(L, &m)
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

// A script returns a table of functions. `feed` is the only one used today.
vm_load :: proc(v: ^Vm, path: string) -> (a: Adapter, ok: bool) {
	v.budget = SLICES
	if lua.L_loadfile(v.L, cstr(path)) != .OK do return 0, fail(v, path)
	if lua.Status(lua.pcall(v.L, 0, 1, 0)) != .OK do return 0, fail(v, path)

	if !lua.istable(v.L, -1) {
		fmt.eprintfln("lua: %s: must return a table", path)
		lua.pop(v.L, 1)
		return 0, false
	}
	ref := Adapter(lua.L_ref(v.L, lua.REGISTRYINDEX))
	v.paths[ref] = strings.clone(path)
	return ref, true
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
	v.budget = SLICES
	v.running = a
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

// ------------------------------------------------------------- commands

@(private = "file")
str_at :: proc(L: ^lua.State, i: c.int) -> string {
	n: c.size_t
	cs := lua.tolstring(L, i, &n)
	if cs == nil do return ""
	return strings.clone(string(([^]byte)(cs)[:n]), context.temp_allocator)
}

@(private = "file")
field_at :: proc(L: ^lua.State, at: c.int, key: cstring) -> string {
	defer lua.pop(L, 1)
	if lua.getfield(L, at, key) != c.int(lua.TSTRING) do return ""
	return str_at(L, -1)
}

// Read a call the adapter described. Every argument crosses as text, and the
// signature says what each one is, because D-Bus is typed and Lua is not.
@(private = "file")
read_call :: proc(L: ^lua.State, at: c.int) -> Cmd_Call {
	out := Cmd_Call{
		dest   = field_at(L, at, "dest"),
		path   = field_at(L, at, "path"),
		iface  = field_at(L, at, "iface"),
		member = field_at(L, at, "member"),
		sig    = field_at(L, at, "sig"),
	}

	args := make([dynamic]string, context.temp_allocator)
	defer lua.pop(L, 1)
	if lua.getfield(L, at, "args") == c.int(lua.TTABLE) {
		for i in 1 ..= int(lua.rawlen(L, -1)) {
			lua.rawgeti(L, -1, lua.Integer(i))
			append(&args, str_at(L, -1))
			lua.pop(L, 1)
		}
	}
	out.args = args[:]
	return out
}

// Offer one command to one adapter. It answers with bytes for its own source,
// a call on its own bus, a refusal, or nothing, which means the command was
// not its.
//
// The fence holds. The script names a call and never makes one, and the
// descriptor the answer travels down is never in its reach.
vm_command :: proc(v: ^Vm, a: Adapter, m: ^Msg) -> Cmd {
	if a == NO_ADAPTER do return nil
	clear(&v.emitted)

	lua.rawgeti(v.L, lua.REGISTRYINDEX, lua.Integer(a))
	if lua.getfield(v.L, -1, "command") != c.int(lua.TFUNCTION) {
		lua.pop(v.L, 2)
		return nil          // an adapter need not take commands
	}
	push_msg(v.L, m)

	v.budget = SLICES
	v.running = a
	if lua.Status(lua.pcall(v.L, 1, 3, 0)) != .OK {
		fail(v, "command")
		lua.pop(v.L, 1)
		return nil
	}
	defer lua.pop(v.L, 4)   // three results and the adapter table

	// A command produces no facts. The state that follows the action shows
	// what it did, which is the rule in kipp's SPEC.md, and an adapter that
	// emits here would be guessing at it.
	if len(v.emitted) > 0 {
		fmt.eprintfln(
`kippsrv: %s emitted %d facts while taking the %q command, and they were
         dropped. This is a bug in that adapter file.
         [E-cmdemit] See DIAGNOSTICS.md.`, v.paths[a], len(v.emitted), m.kind)
		clear(&v.emitted)
	}

	top := lua.gettop(v.L)
	#partial switch lua.type(v.L, top - 2) {
	case .STRING:
		return Cmd_Bytes{str_at(v.L, top - 2)}
	case .TABLE:
		return read_call(v.L, top - 2)
	}

	// Nothing, and a reason: the verb was this adapter's and something about
	// the command was not right.
	if lua.type(v.L, top - 1) == .STRING {
		return Cmd_Fail{str_at(v.L, top - 1), str_at(v.L, top)}
	}
	return nil
}

// Run a string. Used by the sandbox check, never in normal operation.
vm_eval :: proc(v: ^Vm, src: string) -> bool {
	v.budget = SLICES
	if lua.L_loadstring(v.L, cstr(src)) != .OK do return fail(v, "eval")
	if lua.Status(lua.pcall(v.L, 0, 0, 0)) != .OK do return fail(v, "eval")
	return true
}
