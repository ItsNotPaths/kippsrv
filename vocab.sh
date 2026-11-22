#!/bin/sh
# Every adapter this repo ships keeps to the vocabulary of its domain.
#
# It covers sources.d/ and nothing else. A file a user writes lives in their own
# configuration directory, is never seen here, and may emit whatever it likes.
# Nothing at runtime consults these files: the daemon has no vocabulary in it,
# and an unlisted kind reaches a consumer untouched.
#
# It matches quoted literals only. A kind built at run time, k.emit(kind_var,
# ...), is invisible here and to lint-core. The check is partial by
# construction, and its job is to make the ordinary mistake visible in a diff.
#
# sources.d/<domain>-<tool>.lua keeps to the kinds in vocab/<domain>.txt, so two
# adapters of one domain cannot drift apart unseen. A file with no domain in
# its name translates nothing and is skipped. A domain with one
# implementation cannot drift, so the file is documentation. A domain with
# several is where this earns its keep.
set -u
cd "$(dirname "$0")"
fail=0

n=0
for f in sources.d/*-*.lua; do
	domain=$(basename "$f" | cut -d- -f1)
	vocab="vocab/$domain.txt"
	n=$((n + 1))

	if [ ! -f "$vocab" ]; then
		echo "FAIL  $f has no $vocab"
		fail=$((fail + 1))
		continue
	fi
	allowed=$(sed 's/#.*//' "$vocab" | tr -d ' \t' | grep -v '^$' | sort -u)

	for kind in $(grep -oE 'k\.(emit|event|drop)\("[a-z_]+"' "$f" |
	              sed 's/.*"\(.*\)"/\1/' | sort -u); do
		if ! printf '%s\n' "$allowed" | grep -qx "$kind"; then
			echo "FAIL  $f emits '$kind', not in $vocab"
			fail=$((fail + 1))
		fi
	done
done

if [ "$fail" -eq 0 ]; then
	d=$(ls sources.d/*-*.lua | xargs -n1 basename | cut -d- -f1 | sort -u | wc -l)
	echo "ok    $n shipped adapters keep to their vocabulary, $d domains"
fi
exit "$fail"
