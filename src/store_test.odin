package kippsrv

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
apply :: proc(st: ^Store, kind: Emit_Kind, line: string) -> string {
	return store_apply(st, Emit{line, kind, 0})
}

// A source repeats itself constantly. The store passes on only what moved.
@(test)
a_repeat_is_silence :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	first := apply(&st, .State, "tag\teDP-1\t2\tstate=focused")
	testing.expect_value(t, first, "tag\teDP-1\t2\tstate=focused")

	again := apply(&st, .State, "tag\teDP-1\t2\tstate=focused")
	testing.expect_value(t, again, "")             // identical, so nothing

	moved := apply(&st, .State, "tag\teDP-1\t2\tstate=occupied")
	testing.expect_value(t, moved, "tag\teDP-1\t2\tstate=occupied")

	// the key is kind plus subject, so a different tag is a different fact
	other := apply(&st, .State, "tag\teDP-1\t3\tstate=focused")
	testing.expect_value(t, other, "tag\teDP-1\t3\tstate=focused")

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 2)
}

// An event has no current value, so it passes through and is never stored.
@(test)
an_event_is_never_stored :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	apply(&st, .State, "focus\teDP-1")
	testing.expect_value(t, apply(&st, .Event, "key_press\tsuper+3"), "key_press\tsuper+3")
	testing.expect_value(t, apply(&st, .Event, "key_press\tsuper+3"), "key_press\tsuper+3")

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 1)         // only the fact
}

@(test)
a_drop_removes_a_fact :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	apply(&st, .State, "mon\tHDMI-A-1\tw=1920")
	apply(&st, .State, "mon\teDP-1\tw=2256")
	// A retraction goes out as its own kind, so a consumer can tell "forget
	// this" from "this is true and has no attributes".
	testing.expect_value(t, apply(&st, .Drop, "mon\tHDMI-A-1"), "drop\tmon\tHDMI-A-1")
	testing.expect_value(t, apply(&st, .Drop, "mon\tHDMI-A-1"), "")   // already gone

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 do testing.expect_value(t, lines[0], "mon\teDP-1\tw=2256")
}

// The dump is stable, in the order facts were first seen.
@(test)
the_dump_keeps_its_order :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	for line in ([]string{"mon\teDP-1", "focus\teDP-1", "tag\teDP-1\t2\tstate=focused"}) {
		apply(&st, .State, line)
	}
	apply(&st, .State, "mon\teDP-1\tw=2256")       // an update, not a reorder

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 {
		testing.expect_value(t, lines[0], "mon\teDP-1\tw=2256")
		testing.expect_value(t, lines[1], "focus\teDP-1")
	}
}

// The projection is what a script or a short-lived popup reads.
@(test)
the_projection_lands_atomically :: proc(t: ^testing.T) {
	path := "/tmp/kippsrv-projection-test.state"
	os.remove(path)

	st := Store{path = path}
	defer store_close(&st)

	apply(&st, .State, "focus\teDP-1")
	apply(&st, .State, "tag\teDP-1\t2\tstate=focused")
	store_project(&st)

	src, rerr := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, rerr == nil, "the projection was not written") do return
	fmt.printfln("\n--- %s\n%s", path, string(src))
	testing.expect_value(t, string(src), "focus\teDP-1\ntag\teDP-1\t2\tstate=focused\n")

	// nothing moved, so nothing is rewritten
	testing.expect(t, !st.dirty, "clean after a write")
	os.remove(path)
	store_project(&st)
	_, again := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, again != nil, "a clean store writes nothing")

}

// A source that dies leaves last-known facts, not a lie. A headphone still
// exists after bluez stops answering, so the fact is marked rather than
// removed, and a consumer can grey it out.
@(test)
a_dead_source_leaves_stale_facts :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	store_apply(&st, Emit{"bt\t00:11\tname=Buds\tstate=connected", .State, 7})
	store_apply(&st, Emit{"net\twlp4s0\tstate=up", .State, 9})

	out := store_stale(&st, 7)
	testing.expect_value(t, len(out), 1)
	if len(out) == 1 do testing.expect_value(t, out[0], "stale\tbt\t00:11")

	// only that source, and only once
	testing.expect_value(t, len(store_stale(&st, 7)), 0)

	// the dump carries the fact and its mark, so a late consumer knows too
	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 3)

	// the source comes back, and the return is news even though the value
	// did not change
	back := store_apply(&st, Emit{"bt\t00:11\tname=Buds\tstate=connected", .State, 7})
	testing.expect_value(t, back, "bt\t00:11\tname=Buds\tstate=connected")

	lines2 := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines2)
	testing.expect_value(t, len(lines2), 2)   // the mark is gone
}
