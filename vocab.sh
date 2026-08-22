#!/bin/sh
# Every adapter this repo ships keeps to the vocabulary of its domain.
#
# It covers lua/ and nothing else. An adapter a user writes lives in their own
# configuration directory, is never seen here, and may emit whatever it likes.
# Nothing at runtime consults these files: the daemon has no vocabulary in it,
# and an unlisted kind reaches a consumer untouched.
#
# lua/<domain>/<impl>.lua may emit only the kinds in vocab/<domain>.txt. A new
# kind is an edit to that file, which is a deliberate act. A domain with one
# implementation cannot drift, so the file is documentation. A domain with
# several is where this earns its keep.
set -u
cd "$(dirname "$0")"
fail=0

for dir in lua/*/; do
	domain=$(basename "$dir")
	vocab="vocab/$domain.txt"

	if [ ! -f "$vocab" ]; then
		echo "FAIL  lua/$domain/ has no $vocab"
		fail=$((fail + 1))
		continue
	fi
	allowed=$(sed 's/#.*//' "$vocab" | tr -d ' \t' | grep -v '^$' | sort -u)

	for f in "$dir"*.lua; do
		[ -e "$f" ] || continue
		for kind in $(grep -oE 'k\.(emit|event|drop)\("[a-z_]+"' "$f" |
		              sed 's/.*"\(.*\)"/\1/' | sort -u); do
			if ! printf '%s\n' "$allowed" | grep -qx "$kind"; then
				echo "FAIL  $f emits '$kind', not in $vocab"
				fail=$((fail + 1))
			fi
		done
	done
done

if [ "$fail" -eq 0 ]; then
	n=$(ls lua/*/*.lua 2>/dev/null | wc -l)
	d=$(ls -d lua/*/ 2>/dev/null | wc -l)
	echo "ok    $n shipped adapters keep to their vocabulary, $d domains"
fi
exit "$fail"
