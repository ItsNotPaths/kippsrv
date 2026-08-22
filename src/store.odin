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

Store :: struct {
	facts: map[string]string,   // key -> the whole line
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
		delete(v)
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
		delete(old)
		for o, i in st.order {
			if o == k {
				delete(o)
				ordered_remove(&st.order, i)
				break
			}
		}
		st.dirty = true
		return e.line
	}

	if old, had := st.facts[k]; had {
		if old == e.line do return ""      // a repeat is silence
		delete(old)
		st.facts[k] = strings.clone(e.line)
	} else {
		owned := strings.clone(k)
		st.facts[owned] = strings.clone(e.line)
		append(&st.order, owned)
	}
	st.dirty = true
	return e.line
}

// Everything true right now, in the order it was first seen.
store_each :: proc(st: ^Store, out: ^[dynamic]string) {
	for k in st.order {
		if line, ok := st.facts[k]; ok do append(out, line)
	}
}

// The projection. A script or a popup that will not hold a connection reads
// this instead. Written once a pass, and only when something moved.
store_project :: proc(st: ^Store) {
	if !st.dirty || st.path == "" do return
	st.dirty = false

	b := strings.builder_make(context.temp_allocator)
	for k in st.order {
		if line, ok := st.facts[k]; ok {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	text := strings.to_string(b)
	write_atomic(st.path, transmute([]byte)text)
}
