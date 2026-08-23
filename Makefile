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

check: kippsrv tenet
	$(ODIN) test src
	./check.sh

tenet: tenet-core tenet-fd tenet-api tenet-vocab

# Pillar 1: the core must not learn a domain noun. Comments are stripped
# first: prose that names a noun as an example is explaining the boundary,
# not crossing it.
tenet-core:
	@fail=0; for f in $(CORE); do \
		if sed 's|//.*||' $$f | grep -nqE '\b(tag|workspace|volume|bluetooth|battery|theme)\b'; then \
			echo "$$f names a domain noun in code"; fail=1; \
		fi; \
	done; \
	[ $$fail -eq 0 ] || exit 1; \
	echo "ok    core knows no domain"

# A12: a script never owns a descriptor. The VM file must not reach posix.
tenet-fd:
	@! grep -n 'posix' src/lua.odin \
		|| { echo "the VM file reached posix"; exit 1; }
	@echo "ok    scripts hold no descriptor"

# ideas.txt puts wweft's script surface at about forty tagged lines.
tenet-api:
	@n=$$(grep -c '@api' src/lua.odin); \
	[ "$$n" -le 60 ] || { echo "api is $$n tagged lines, cap is 60"; exit 1; }; \
	echo "ok    api is $$n tagged lines"

# An adapter may emit only the kinds its domain declares.
tenet-vocab:
	@./vocab.sh

clean:
	rm -f kippsrv

distclean: clean
	rm -rf basu

.PHONY: check static tenet tenet-core tenet-fd tenet-api tenet-vocab clean distclean
