ODIN   ?= odin
PREFIX ?= /usr/local
CORE    = $(wildcard src/*.odin)

# kippbus links basu, sd-bus without systemd, so it needs no D-Bus library at
# run time. kippsrv links no bus at all.
BASU_REPO ?= https://git.sr.ht/~emersion/basu
BASU_REV  ?= 315664a875ad37bd9cee75af00ab4d1d3edc105e

all: kippsrv kippbus

kippsrv: src/*.odin
	$(ODIN) build src -out:$@

kippbus: basu/build/libbasu.a bus/*.odin
	$(ODIN) build bus -out:$@ -extra-linker-flags:"-L$(CURDIR)/basu/build"

# basu is pinned to a commit and built once. It is not copied into this repo:
# 34k lines of someone else's C does not belong in the tree, and a pin gives
# the same reproducibility without them.
basu/build/libbasu.a:
	@for tool in meson ninja gperf; do \
		command -v $$tool >/dev/null || { echo "basu needs meson, ninja and gperf: no $$tool"; exit 1; }; \
	done
	rm -rf basu
	git clone -q $(BASU_REPO) basu
	cd basu && git checkout -q $(BASU_REV)
	meson setup basu/build basu --default-library=static --buildtype=release \
		-Daudit=disabled -Dlibcap=disabled
	ninja -C basu/build libbasu.a

# The layout a release tarball unpacks into, and what XDG_DATA_DIRS finds.
install: all
	install -Dm755 -t $(DESTDIR)$(PREFIX)/bin kippsrv kippbus
	install -Dm644 -t $(DESTDIR)$(PREFIX)/share/kippsrv/sources.d sources.d/*.lua

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/kippsrv $(DESTDIR)$(PREFIX)/bin/kippbus
	rm -rf $(DESTDIR)$(PREFIX)/share/kippsrv

check: kippsrv kippbus lint
	$(ODIN) test tests
	./tests/check.sh

lint: lint-core lint-fd lint-api

# Pillar 1: the core must not name a domain kind.
#
# The kinds are the ones sources.d/ emits, not a list typed here, so a kind is
# forbidden in the core the day an adapter starts emitting it.
#
# It matches quoted string literals, because naming a kind means writing one.
# Comments are stripped first: prose that names a kind as an example explains
# the boundary rather than crossing it.
lint-core:
	@kinds=$$(grep -ohE 'k\.(retain|publish)\("[a-z_]+' sources.d/*.lua | sed 's/.*"//' | \
		sort -u | paste -sd'|'); \
	fail=0; for f in $(CORE); do \
		hit=$$(sed 's|//.*||' $$f | grep -oE "\"($$kinds)\"" | sort -u | tr '\n' ' '); \
		if [ -n "$$hit" ]; then echo "$$f names domain kinds: $$hit"; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ] || exit 1; \
	echo "ok    core names none of $$(echo $$kinds | tr '|' '\n' | wc -l) adapter kinds"

# A12: a script never owns a descriptor. The VM file must not reach posix.
lint-fd:
	@! grep -n 'posix' src/lua.odin \
		|| { echo "the VM file reached posix"; exit 1; }
	@echo "ok    scripts hold no descriptor"

# ideas.txt puts wweft's script surface at about forty tagged lines.
#
# It counts registrations on the k table, not @api comments. Counting comments
# measures the discipline this check exists to replace: a call added without a
# comment would pass at the old number.
lint-api:
	@n=$$(grep -c 'lua.pushcfunction' src/lua.odin); \
	[ "$$n" -le 12 ] || { echo "script surface is $$n functions, cap is 12"; exit 1; }; \
	echo "ok    script surface is $$n functions"

clean:
	rm -f kippsrv kippbus

distclean: clean
	rm -rf basu

.PHONY: all install uninstall check lint lint-core lint-fd lint-api clean distclean
