#!/bin/sh
# Start the server, talk to it with socat, check what comes back.
set -u
cd "$(dirname "$0")"

SOCK=/tmp/kippsrv-check.$$.sock
FAILS=0

cleanup() { kill "$SRV" 2>/dev/null; rm -f "$SOCK"; }
trap cleanup EXIT

./kippsrv "$SOCK" 2>/dev/null &
SRV=$!
sleep 0.3

want() {
	name=$1 pattern=$2 send=$3
	out=$(printf '%s' "$send" | timeout 2 socat -t1 - UNIX-CONNECT:"$SOCK" 2>/dev/null)
	if printf '%s' "$out" | grep -q "$pattern"; then
		echo "ok    $name"
	else
		echo "FAIL  $name (no match for '$pattern')"
		FAILS=$((FAILS + 1))
	fi
}

want greeting 'version	1	kippsrv' ''
want dump     'mon	eDP-1	w=2256' ''
want sync     '^sync	state$' ''
want command  'tag	eDP-1	7' 'TAG	7
'
want error    'error	badcmd	cmd=NOPE' 'NOPE
'

[ "$FAILS" -eq 0 ] && echo "kippsrv ok" || echo "$FAILS failed"
exit "$FAILS"
