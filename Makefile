ODIN ?= odin

kippsrv: src/*.odin
	$(ODIN) build src -out:$@

check: kippsrv tenet
	$(ODIN) test src
	./check.sh

tenet: tenet-core tenet-fd tenet-api tenet-vocab

# Pillar 1: the core must not learn a domain noun.
tenet-core:
	@! grep -nE '\b(tag|workspace|volume|bluetooth|battery|theme)\b' \
		src/kipp.odin src/loop.odin src/lua.odin \
		|| { echo "core learned a domain noun"; exit 1; }
	@echo "ok    core knows no domain"

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

.PHONY: check tenet tenet-core tenet-fd tenet-api tenet-vocab clean
