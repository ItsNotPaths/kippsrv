// Current truth.
//
// Current truth: the last value of each fact, and only what moved goes out.
// It also answers the dump, so a consumer can connect at any moment and know
// the truth without having heard the history.
package kippsrv

import "core:fmt"
import "core:strings"

Fact :: struct {
	line:  string,
	src:   int,    // which source produced it, so its death can be answered
	stale: bool,   // the source is gone. This is last-known, not current
}

// An adapter that keys on something unbounded would otherwise grow the store
// until the daemon is killed. vocab/wm.txt warns against it; this bounds it.
MAX_FACTS    :: 4096
PROJECT_MS   :: 250    // shortest gap between two writes of the state file

Store :: struct {
	facts: map[string]Fact,
	order: [dynamic]string,     // keys in the order first seen, so a dump is stable
	path:  string,              // the state file, or "" for none
	dirty: bool,
	full:  bool,                // the cap was reported once
	wrote: i64,                 // when the projection last landed
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
//
// A fact is identified by its topic. The payload is the value, so
// `retain tag/eDP-1/2 state=occupied` replaces `retain tag/eDP-1/2
// state=focused` instead of sitting beside it.
store_apply :: proc(st: ^Store, e: Emit) -> string {
	m, ok := parse(e.line, context.temp_allocator)
	if !ok || m.topic == "" do return ""
	if m.verb != "retain" do return e.line   // no current value, nothing to store

	k := m.topic
	if len(m.payload) == 0 {
		old, had := st.facts[k]
		if !had do return ""
		for o, i in st.order {
			if o == k {
				delete_key(&st.facts, k)
				delete(old.line)
				delete(o)
				ordered_remove(&st.order, i)
				break
			}
		}
		st.dirty = true
		return e.line
	}

	if old, had := st.facts[k]; had {
		// A repeat is silence, unless the fact was stale: then its return is
		// news, because a consumer is showing it greyed out.
		if old.line == e.line && !old.stale do return ""
		delete(old.line)
		st.facts[k] = {strings.clone(e.line), e.src, false}
	} else {
		if len(st.order) >= MAX_FACTS {
			if !st.full {
				st.full = true
				fmt.eprintfln(
`kippsrv: reached %d stored facts and is refusing more, so parts of your
         desktop will stop updating. An adapter is using something unbounded
         as a subject. This is a bug in an adapter, not in your configuration.
         [E-full] See DIAGNOSTICS.md.`, MAX_FACTS)
			}
			return ""
		}
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

// A source died. Its facts are last-known, not gone: the headphone still
// exists, we just cannot see it.
// (hole status-topic :tags broker) marks each fact of a dead source stale; proposed v2: retain status/<source> state=offline.
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

	// A busy desktop would otherwise rename this file hundreds of times a
	// second, and every watcher of the directory would wake for each one.
	now := now_ms()
	if now - st.wrote < PROJECT_MS do return
	st.wrote = now
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
