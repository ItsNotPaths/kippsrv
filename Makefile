ODIN ?= odin
CORE  = $(filter-out %_test.odin,$(wildcard src/*.odin))

# sd-bus has two implementations. libsystemd is the default because a systemd
# machine already has it. `make static` uses basu instead and links it in, so
# the binary needs no D-Bus library at all. That is the form to package.
BASU_REPO ?= https://git.sr.ht/~emersion/basu
BASU_REV  ?= 315664a875ad37bd9cee75af00ab4d1d3edc105e

kippsrv: src/*.odin
	$(ODIN) build src -out:$@

static: basu/build/libbasu.a src/*.odin
	$(ODIN) build src -define:BASU=true -out:kippsrv \
		-extra-linker-flags:"-L$(CURDIR)/basu/build"

# basu is pinned to a commit and built once. It is not copied into this repo:
# 34k lines of someone else's C does not belong in the tree, and a pin gives
# the same reproducibility without them.
basu/build/libbasu.a:
	@command -v meson >/dev/null || { echo "need meson, ninja and gperf"; exit 1; }
	rm -rf basu
	git clone -q $(BASU_REPO) basu
	cd basu && git checkout -q $(BASU_REV)
	meson setup basu/build basu --default-library=static --buildtype=release \
		-Daudit=disabled -Dlibcap=disabled
	ninja -C basu/build libbasu.a

check: kippsrv lint
	$(ODIN) test src
	./check.sh

lint: lint-core lint-fd lint-api lint-vocab

# Pillar 1: the core must not name a domain kind.
#
# The list is derived from vocab/, not typed here. A hand-kept list decays as
# the vocabulary grows, because each new kind is one more word to remember. A
# derived one gets stronger: declaring a kind forbids it in the core that day.
#
# It matches quoted string literals, because naming a kind means writing one.
# Comments are stripped first: prose that names a kind as an example explains
# the boundary rather than crossing it.
lint-core:
	@kinds=$$(sed 's/#.*//' vocab/*.txt | tr -d ' \t' | grep -v '^$$' | \
		sort -u | paste -sd'|'); \
	fail=0; for f in $(CORE); do \
		hit=$$(sed 's|//.*||' $$f | grep -oE "\"($$kinds)\"" | sort -u | tr '\n' ' '); \
		if [ -n "$$hit" ]; then echo "$$f names domain kinds: $$hit"; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ] || exit 1; \
	echo "ok    core names none of $$(sed 's/#.*//' vocab/*.txt | tr -d ' \t' | \
		grep -v '^$$' | sort -u | wc -l) declared kinds"

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

# An adapter may emit only the kinds its domain declares.
lint-vocab:
	@./vocab.sh

clean:
	rm -f kippsrv

distclean: clean
	rm -rf basu

.PHONY: check static lint lint-core lint-fd lint-api lint-vocab clean distclean
