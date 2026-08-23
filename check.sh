#!/bin/sh
# Start the daemon from a configuration, talk to it with socat, check what
# comes back. socat is a first-class client, so the checks use nothing else.
set -u
cd "$(dirname "$0")"

SOCK=/tmp/kippsrv-check.$$.sock
CONF=/tmp/kippsrv-check.$$.lua
FAILS=0

cleanup() { kill "$SRV" 2>/dev/null; rm -f "$SOCK" "$SOCK.state" "$CONF"; }
trap cleanup EXIT

# The source ends long before the consumer connects. Everything the consumer
# sees comes out of the store.
cat > "$CONF" <<CONFEOF
return {
	socket = "$SOCK",
	state  = "$SOCK.state",
	sources = {
		{ name = "wm", adapter = "lua/wm/dwl.lua",
		  exec = {"cat", "test/fmt/dwl.txt"} },
	},
}
CONFEOF

./kippsrv "$CONF" 2>/dev/null &
SRV=$!
sleep 0.4

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

want greeting   'version	1	kippsrv'          ''
want dump       'tag	0	1	state=occupied'   ''
want late       'focus	0'                     ''
want sync       '^sync	state$'                ''
want no_forgery 'error	badcmd	cmd=tag'       'tag	0	9	state=focused
'
want no_command 'no adapter takes commands'    'TAG	9
'

# D-Bus needs a live session bus and busctl. Missing either is a skip.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	DSOCK=/tmp/kippsrv-dbus.$$.sock
	DCONF=/tmp/kippsrv-dbus.$$.lua
	cat > "$DCONF" <<DCONFEOF
return {
	socket = "$DSOCK",
	sources = {
		{ name = "test", adapter = "test/lua/dbus_echo.lua",
		  dbus = {"type='signal',interface='org.kippsrv.Test'"} },
	},
}
DCONFEOF
	./kippsrv "$DCONF" 2>/dev/null &
	DSRV=$!
	sleep 0.4
	timeout 3 socat -u UNIX-CONNECT:"$DSOCK" - > /tmp/kippsrv-dbus.$$.out 2>/dev/null &
	sleep 0.4
	busctl --user emit /x org.kippsrv.Test Sig "sa{sv}" hello 2 k1 s v1 k2 i 42 >/dev/null 2>&1
	sleep 1.5
	# a variant is collapsed the way busctl collapses it, so one adapter
	# works whether a fact was polled or pushed
	if grep -q 's=hello	k1=v1	k2=42' /tmp/kippsrv-dbus.$$.out 2>/dev/null; then
		echo "ok    dbus signal converted"
	else
		echo "FAIL  dbus signal not converted"
		FAILS=$((FAILS + 1))
	fi
	kill "$DSRV" 2>/dev/null
	rm -f "$DSOCK" "$DCONF" /tmp/kippsrv-dbus.$$.out
else
	echo "skip  dbus (no busctl or no session bus)"
fi

# The watcher owns a test name, never the real one. Taking
# org.kde.StatusNotifierWatcher stops whatever holds it, which is not a thing
# a test does.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	WSOCK=/tmp/kippsrv-w.$$.sock
	WCONF=/tmp/kippsrv-w.$$.lua
	WNAME=org.kippsrv.CheckWatcher.p$$
	cat > "$WCONF" <<WCONFEOF
return {
	socket = "$WSOCK",
	state  = "$WSOCK.state",
	sources = { { name = "watcher", watcher = true, bus_name = "$WNAME",
	              adapter = "lua/tray/snw.lua" } },
}
WCONFEOF
	./kippsrv "$WCONF" 2>/dev/null &
	WSRV=$!
	sleep 0.4
	busctl --user call "$WNAME" /StatusNotifierWatcher \
		org.kde.StatusNotifierWatcher RegisterStatusNotifierItem s org.test.Item \
		>/dev/null 2>&1
	got=$(busctl --user get-property "$WNAME" /StatusNotifierWatcher \
		org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null)
	tray=$(grep -c '^tray' "$WSOCK.state" 2>/dev/null || echo 0)
	if printf '%s' "$got" | grep -q 'org.test.Item'; then
		echo "ok    watcher owns a name and registers an item"
	else
		echo "FAIL  watcher did not register ($got)"
		FAILS=$((FAILS + 1))
	fi
	if [ "$tray" -ge 1 ]; then
		echo "ok    the tray kind is named in Lua, not in the core"
	else
		echo "FAIL  no tray fact reached the store"
		FAILS=$((FAILS + 1))
	fi
	kill "$WSRV" 2>/dev/null
	rm -f "$WSOCK" "$WSOCK.state" "$WCONF"
else
	echo "skip  watcher (no busctl or no session bus)"
fi

if [ -s "$SOCK.state" ]; then
	echo "ok    projection written"
else
	echo "FAIL  projection missing or empty"
	FAILS=$((FAILS + 1))
fi

[ "$FAILS" -eq 0 ] && echo "kippsrv ok" || echo "$FAILS failed"
exit "$FAILS"
