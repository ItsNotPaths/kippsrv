package kippsrv

import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
apply :: proc(st: ^Store, line: string) -> string {
	return store_apply(st, Emit{line, 0})
}

// A source repeats itself constantly. The store passes on only what moved.
@(test)
a_repeat_is_silence :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	first := apply(&st, "retain\ttag/eDP-1/2\tstate=focused")
	testing.expect_value(t, first, "retain\ttag/eDP-1/2\tstate=focused")

	again := apply(&st, "retain\ttag/eDP-1/2\tstate=focused")
	testing.expect_value(t, again, "")             // identical, so nothing

	moved := apply(&st, "retain\ttag/eDP-1/2\tstate=occupied")
	testing.expect_value(t, moved, "retain\ttag/eDP-1/2\tstate=occupied")

	// the key is the topic, so a different tag is a different fact
	other := apply(&st, "retain\ttag/eDP-1/3\tstate=focused")
	testing.expect_value(t, other, "retain\ttag/eDP-1/3\tstate=focused")

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 2)
}

// An event has no current value, so it passes through and is never stored.
@(test)
an_event_is_never_stored :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	apply(&st, "retain\tfocus\toutput=eDP-1")
	testing.expect_value(t, apply(&st, "publish\tkey_press/super+3"), "publish\tkey_press/super+3")
	testing.expect_value(t, apply(&st, "publish\tkey_press/super+3"), "publish\tkey_press/super+3")

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 1)         // only the fact
}

@(test)
an_empty_retain_forgets_a_topic :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	apply(&st, "retain\tmon/HDMI-A-1\tw=1920")
	apply(&st, "retain\tmon/eDP-1\tw=2256")
	// A retain with no payload forgets the topic and goes out as it came, so
	// a reader forgets it too.
	testing.expect_value(t, apply(&st, "retain\tmon/HDMI-A-1"), "retain\tmon/HDMI-A-1")
	testing.expect_value(t, apply(&st, "retain\tmon/HDMI-A-1"), "")   // already gone

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 1)
	if len(lines) == 1 do testing.expect_value(t, lines[0], "retain\tmon/eDP-1\tw=2256")
}

// The dump is stable, in the order facts were first seen.
@(test)
the_dump_keeps_its_order :: proc(t: ^testing.T) {
	st: Store
	defer store_close(&st)

	for line in ([]string{"retain\tmon/eDP-1\tw=1920", "retain\tfocus\toutput=eDP-1", "retain\ttag/eDP-1/2\tstate=focused"}) {
		apply(&st, line)
	}
	apply(&st, "retain\tmon/eDP-1\tw=2256")       // an update, not a reorder

	lines := make([dynamic]string, context.temp_allocator)
	store_each(&st, &lines)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 {
		testing.expect_value(t, lines[0], "retain\tmon/eDP-1\tw=2256")
		testing.expect_value(t, lines[1], "retain\tfocus\toutput=eDP-1")
	}
}

// The projection is what a script or a short-lived popup reads.
@(test)
the_projection_lands_atomically :: proc(t: ^testing.T) {
	path := "/tmp/kippsrv-projection-test.state"
	os.remove(path)

	st := Store{path = path}
	defer store_close(&st)

	apply(&st, "retain\tfocus\toutput=eDP-1")
	apply(&st, "retain\ttag/eDP-1/2\tstate=focused")
	store_project(&st)

	src, rerr := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, rerr == nil, "the projection was not written") do return
	fmt.printfln("\n--- %s\n%s", path, string(src))
	testing.expect_value(t, string(src), "retain\tfocus\toutput=eDP-1\nretain\ttag/eDP-1/2\tstate=focused\n")

	// nothing moved, so nothing is rewritten
	testing.expect(t, !st.dirty, "clean after a write")
	os.remove(path)
	store_project(&st)
	_, again := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, again != nil, "a clean store writes nothing")

}
