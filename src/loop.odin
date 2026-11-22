// The event loop. The only place in the program that blocks.
package kippsrv

import "core:sys/posix"

MAX_POLL :: 64

Loop :: struct {
	srv:     ^Server,
	src:     ^Sources,
	store:   ^Store,
	running: bool,
}

quit :: proc(l: ^Loop) {
	l.running = false
}

run :: proc(l: ^Loop) {
	fds: [MAX_POLL]posix.pollfd
	hit: [MAX_POLL]posix.FD
	from_srv: [MAX_POLL]bool

	publish(l, src_status(l.src))   // every source starts online

	l.running = true
	for l.running {
		nsrv := srv_fds(l.srv, fds[:])
		nall := nsrv + src_fds(l.src, fds[nsrv:])

		// A projection the throttle held back needs a wake of its own.
		now := now_ms()
		wait := src_timeout(l.src, now)
		if due := store_timeout(l.store, now); due >= 0 && (wait < 0 || due < wait) do wait = due

		if posix.poll(&fds[0], posix.nfds_t(nall), wait) > 0 {
			// Copy the ready descriptors out first. Dispatching can drop a
			// consumer or end a source, and the set must not shift under us.
			n := 0
			for i in 0 ..< nall {
				if fds[i].revents == {} do continue
				hit[n] = fds[i].fd
				from_srv[n] = i < nsrv
				n += 1
			}
			for i in 0 ..< n {
				if from_srv[i] {
					srv_ready(l.srv, hit[i])
				} else {
					publish(l, src_ready(l.src, hit[i]))
				}
			}
		}
		src_reap(l.src)
		publish(l, src_tick(l.src, now_ms()))
		src_settle(l.src)
		publish(l, src_status(l.src))
		publish(l, watcher_facts(l.src))
		store_project(l.store)
		srv_flush(l.srv)

		// Every line built in a pass lives in the temp allocator and dies
		// with the pass. Nothing in the loop reaches the heap.
		free_all(context.temp_allocator)
	}
}

// Everything a source produced goes through the store, which drops a repeat
// and passes on a change. A consumer sees a line only when something moved,
// and the source that moved it is credited, so a quiet one can back off.
@(private = "file")
publish :: proc(l: ^Loop, es: []Emit) {
	for e in es {
		// (hole claims) a source may retain any topic; v2 refuses a retain outside the source's claim.
		line := store_apply(l.store, e)
		if line == "" do continue
		broadcast(l.srv, line)
		src_moved(l.src, e.src)
	}
}

