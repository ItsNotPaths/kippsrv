// Current truth.
//
// A source repeats itself. `nmcli` re-prints every connection each time
// anything changes, and a poll re-reads the same battery percentage all day.
// The store keeps the last value for each fact and passes on only what moved,
// so a repeat is silence.
//
// It also answers the dump, which is what lets a consumer connect at any
// moment and know the truth without having heard the history.
package kippsrv

import "core:strings"

Fact :: struct {
	line:  string,
	src:   int,    // which source produced it, so its death can be answered
	stale: bool,   // the source is gone. This is last-known, not current
}

Store :: struct {
	facts: map[string]Fact,
	order: [dynamic]string,     // keys in the order first seen, so a dump is stable
	path:  string,              // the state file, or "" for none
	dirty: bool,
}

// A fact is identified by its kind and its positional subject. The attributes
// are the value, so `tag eDP-1 2 state=occupied` replaces
// `tag eDP-1 2 state=focused` instead of sitting beside it.
@(private = "file")
key_of :: proc(line: string, allocator := context.allocator) -> (string, bool) {
	m, ok := parse(line, context.temp_allocator)
	if !ok do return "", false

	b := strings.builder_make(allocator)
	strings.write_string(&b, m.kind)
	for s in m.subj {
		strings.write_byte(&b, '\t')
		strings.write_string(&b, s)
	}
	return strings.to_string(b), true
}

store_close :: proc(st: ^Store) {
	for k, v in st.facts {
		delete(k)
		delete(v.line)
	}
	delete(st.facts)
	delete(st.order)
}

// Apply one thing an adapter produced. Returns what a consumer should see,
// or "" when nothing changed.
store_apply :: proc(st: ^Store, e: Emit) -> string {
	if e.kind == .Event do return e.line   // no current value, nothing to store

	k, ok := key_of(e.line)
	if !ok do return ""
	defer delete(k)

	if e.kind == .Drop {
		old, had := st.facts[k]
		if !had do return ""
		delete_key(&st.facts, k)
		delete(old.line)
		for o, i in st.order {
			if o == k {
				delete(o)
				ordered_remove(&st.order, i)
				break
			}
		}
		st.dirty = true

		// A retraction is its own kind. Sending the fact back with no
		// attributes would be indistinguishable from a fact that has none,
		// and a consumer must be able to tell "forget this" from "this is
		// true and empty".
		o: Out
		begin(&o, "drop")
		for f in strings.split(k, "\t", context.temp_allocator) do add(&o, "%s", f)
		line, ok := str(&o)
		return ok ? strings.clone(line, context.temp_allocator) : ""
	}

	if old, had := st.facts[k]; had {
		// A repeat is silence, unless the fact was stale: then its return is
		// news, because a consumer is showing it greyed out.
		if old.line == e.line && !old.stale do return ""
		delete(old.line)
		st.facts[k] = {strings.clone(e.line), e.src, false}
	} else {
		owned := strings.clone(k)
		st.facts[owned] = {strings.clone(e.line), e.src, false}
		append(&st.order, owned)
	}
	st.dirty = true
	return e.line
}

// Everything true right now, in the order it was first seen.
store_each :: proc(st: ^Store, out: ^[dynamic]string) {
	for k in st.order {
		f, ok := st.facts[k]
		if !ok do continue
		append(out, f.line)
		if f.stale do append(out, stale_line(k))
	}
}

@(private = "file")
stale_line :: proc(key: string) -> string {
	o: Out
	begin(&o, "stale")
	for f in strings.split(key, "\t", context.temp_allocator) do add(&o, "%s", f)
	line, ok := str(&o)
	return ok ? strings.clone(line, context.temp_allocator) : ""
}

// A source died. Its facts are last-known, not current, and a bar can show
// them greyed rather than lie by removing a headphone that still exists.
store_stale :: proc(st: ^Store, src: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if src == 0 do return out[:]

	for k in st.order {
		f, ok := st.facts[k]
		if !ok || f.src != src || f.stale do continue
		f.stale = true
		st.facts[k] = f
		st.dirty = true
		if line := stale_line(k); line != "" do append(&out, line)
	}
	return out[:]
}

// The projection. A script or a popup that will not hold a connection reads
// this instead. Written once a pass, and only when something moved.
store_project :: proc(st: ^Store) {
	if !st.dirty || st.path == "" do return
	st.dirty = false

	b := strings.builder_make(context.temp_allocator)
	for k in st.order {
		f, ok := st.facts[k]
		if !ok do continue
		strings.write_string(&b, f.line)
		strings.write_byte(&b, '\n')
		if f.stale {
			strings.write_string(&b, stale_line(k))
			strings.write_byte(&b, '\n')
		}
	}
	text := strings.to_string(b)
	write_atomic(st.path, transmute([]byte)text)
}
