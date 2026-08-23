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

	l.running = true
	for l.running {
		nsrv := srv_fds(l.srv, fds[:])
		nall := nsrv + src_fds(l.src, fds[nsrv:])

		if posix.poll(&fds[0], posix.nfds_t(nall), src_timeout(l.src, now_ms())) > 0 {
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
					src_report(l.src, publish(l, src_ready(l.src, hit[i])))
				}
			}
		}
		reap()
		publish(l, src_tick(l.src, now_ms()))
		for id in src_reap(l.src) {
			for line in store_stale(l.store, id) do broadcast(l.srv, line)
		}
		publish(l, watcher_facts(l.src))
		store_project(l.store)
		srv_flush(l.srv)

		// Every line built in a pass lives in the temp allocator and dies
		// with the pass. Nothing in the loop reaches the heap.
		free_all(context.temp_allocator)
	}
}

// Everything a source produced goes through the store, which drops a repeat
// and passes on a change. A consumer sees a line only when something moved.
@(private = "file")
publish :: proc(l: ^Loop, es: []Emit) -> int {
	n := 0
	for e in es {
		line := store_apply(l.store, e)
		if line != "" {
			broadcast(l.srv, line)
			n += 1
		}
	}
	return n
}

