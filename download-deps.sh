#!/bin/sh
# Get what kippsrv needs to build. Run this one time after you clone.
#
# It checks for the tools and says which are missing; installing them is yours.
# Then it builds basu, sd-bus without systemd, into vendor/basu. basu is pinned
# to a commit and not copied into this repo: 34k lines of someone else's C do
# not belong in the tree, and the pin gives the same build every time.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
basu="$root/vendor/basu"

BASU_REPO=https://git.sr.ht/~emersion/basu
BASU_COMMIT=315664a875ad37bd9cee75af00ab4d1d3edc105e

force=0
[ "${1:-}" = "--force" ] && force=1

say() { printf '==> %s\n' "$1"; }

# ------------------------------------------------------------------- tools
missing=""
for tool in odin git meson ninja gperf; do
	command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
	echo "missing:$missing" >&2
	echo "odin builds kippsrv and kippbus; git, meson, ninja and gperf build basu." >&2
	echo "Install them with your package manager, then run this again." >&2
	exit 1
fi
for tool in socat dbus-run-session; do
	command -v "$tool" >/dev/null 2>&1 ||
		echo "note: no $tool. './build.sh test' needs it for its round trip checks."
done

# -------------------------------------------------------------------- basu
if [ -f "$basu/build/libbasu.a" ] && [ "$force" = 0 ]; then
	say "basu already built (--force rebuilds it)"
	exit 0
fi

say "basu $BASU_COMMIT"
rm -rf "$basu"
git clone -q "$BASU_REPO" "$basu"
git -C "$basu" checkout -q "$BASU_COMMIT"
meson setup "$basu/build" "$basu" --default-library=static --buildtype=release \
	-Daudit=disabled -Dlibcap=disabled
ninja -C "$basu/build" libbasu.a
say "done"
