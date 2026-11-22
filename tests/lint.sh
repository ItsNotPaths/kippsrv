#!/bin/sh
# Three architecture rules, checked as text. A determined author can route
# around a grep; what the check buys is that they have to notice.
set -u
cd "$(dirname "$0")/.."
fail=0

# The core must not name a topic kind. The kinds are the ones sources.d/
# emits, not a list typed here, so a kind is forbidden in the core the day an
# adapter starts emitting it.
#
# It matches quoted string literals, because naming a kind means writing one.
# Comments are stripped first: prose that names a kind as an example explains
# the boundary rather than crossing it.
kinds=$(grep -ohE 'k\.(retain|publish)\("[a-z_]+' sources.d/*.lua | sed 's/.*"//' | sort -u)
pattern=$(printf '%s\n' "$kinds" | paste -sd'|')
core_failed=0
for file in src/*.odin; do
	hit=$(sed 's|//.*||' "$file" | grep -oE "\"($pattern)\"" | sort -u | tr '\n' ' ')
	if [ -n "$hit" ]; then
		echo "FAIL  $file names topic kinds: $hit"
		core_failed=1
	fi
done
if [ "$core_failed" = 0 ]; then
	echo "ok    core names none of $(printf '%s\n' "$kinds" | wc -l) adapter kinds"
else
	fail=1
fi

# A script never owns a descriptor, so the VM file must not reach posix.
if grep -n 'posix' src/lua.odin; then
	echo "FAIL  the VM file reached posix"
	fail=1
else
	echo "ok    scripts hold no descriptor"
fi

# It counts registrations on the k table, not @api comments. Counting comments
# measures the discipline this check exists to replace: a call added without a
# comment would pass at the old number.
count=$(grep -c 'lua.pushcfunction' src/lua.odin)
if [ "$count" -le 12 ]; then
	echo "ok    script surface is $count functions"
else
	echo "FAIL  script surface is $count functions, cap is 12"
	fail=1
fi

exit "$fail"
