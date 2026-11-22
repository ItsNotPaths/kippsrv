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

ask() {
	printf '%s' "$1" | timeout 2 socat -t1 - UNIX-CONNECT:"$SOCK" 2>/dev/null
}

want() {
	name=$1 pattern=$2 send=$3
	if ask "$send" | grep -q "$pattern"; then
		echo "ok    $name"
	else
		echo "FAIL  $name (no match for '$pattern')"
		FAILS=$((FAILS + 1))
	fi
}

want_none() {
	name=$1 pattern=$2 send=$3
	if ask "$send" | grep -q "$pattern"; then
		echo "FAIL  $name (got '$pattern')"
		FAILS=$((FAILS + 1))
	else
		echo "ok    $name"
	fi
}

want greeting   'version	2	broker=kippsrv'   ''
want dump       'retain	tag/0/1	state=occupied' 'subscribe	*
'
want late       'retain	layout/0'              'subscribe	*
'
want sync       '^sync	tag/\*$'              'subscribe	tag/*
'
want second_sub '^retain	layout'               'subscribe	tag/*
subscribe	layout/*
'
want_none only_match '^retain	tag/'           'subscribe	layout/*
'
want status     'retain	status/wm	state=online' 'subscribe	status/*
'
want no_forgery 'error	noconnect'             'retain	tag/0/9	state=focused
'
want no_verb    'error	badverb	verb=TAG'      'TAG	9
'
want own_line   '^publish	key/x$'           'subscribe	key/*
publish	key/x
'
want_none unheard '^publish'                'publish	key/x
'

# (hole requests) the v1 command seam is gone; v2 requests bring its check back.
echo "skip  commands (v2 requests are not built)"

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
	{ printf 'subscribe\t*\n'; sleep 3; } | timeout 3 socat - UNIX-CONNECT:"$DSOCK" \
		> /tmp/kippsrv-dbus.$$.out 2>/dev/null &
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
	tray=$(grep -c '^retain	tray/' "$WSOCK.state" 2>/dev/null || echo 0)
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

# The notification server owns a test name, never org.freedesktop.Notifications.
# Taking that one stops whatever holds it, which is not a thing a test does.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	NSOCK=/tmp/kippsrv-n.$$.sock
	NCONF=/tmp/kippsrv-n.$$.lua
	NNAME=org.kippsrv.CheckNotify.p$$
	NPATH=/org/freedesktop/Notifications
	NIFACE=org.freedesktop.Notifications
	cat > "$NCONF" <<NCONFEOF
return {
	socket = "$NSOCK",
	state  = "$NSOCK.state",
	sources = {
		-- The tray comes first on purpose. Every D-Bus source is offered
		-- the servers' state, and the first one to take it clears the flag,
		-- so a notification would reach the tray's adapter and stop there.
		{ name = "tray", watcher = true, bus_name = "$NNAME.w",
		  adapter = "lua/tray/snw.lua" },
		{ name = "notify", notify = true, bus_name = "$NNAME",
		  adapter = "lua/notify/fdo.lua" },
	},
}
NCONFEOF
	./kippsrv "$NCONF" 2>/dev/null &
	NSRV=$!
	sleep 0.4

	# The reply is the id, and the id is what everything else names.
	id=$(busctl --user call "$NNAME" "$NPATH" "$NIFACE" Notify \
		'susssasa{sv}i' grim 0 camera "Screenshot saved" body 0 1 urgency y 2 0 \
		2>/dev/null | awk '{print $2}')
	sleep 0.4
	line=$(grep '^retain	notif/' "$NSOCK.state" 2>/dev/null | head -1)

	if [ "$id" = "1" ]; then
		echo "ok    Notify answers with an id"
	else
		echo "FAIL  Notify did not answer with an id ($id)"
		FAILS=$((FAILS + 1))
	fi
	if printf '%s' "$line" | grep -q 'app=grim' &&
	   printf '%s' "$line" | grep -q 'urgency=critical'; then
		echo "ok    the notif kind is named in Lua, and a hint reaches it"
	else
		echo "FAIL  no usable notif fact reached the store ($line)"
		FAILS=$((FAILS + 1))
	fi

	busctl --user call "$NNAME" "$NPATH" \
		place.paths.kippsrv.Notifications MarkAllRead >/dev/null 2>&1
	sleep 0.4
	if grep '^retain	notif/' "$NSOCK.state" 2>/dev/null | grep -q 'read=1'; then
		echo "ok    a notification can be marked read"
	else
		echo "FAIL  MarkAllRead left nothing read"
		FAILS=$((FAILS + 1))
	fi

	busctl --user call "$NNAME" "$NPATH" "$NIFACE" \
		CloseNotification u "${id:-1}" >/dev/null 2>&1
	sleep 0.4
	if ! grep -q '^retain	notif/' "$NSOCK.state" 2>/dev/null; then
		echo "ok    closing one drops its fact"
	else
		echo "FAIL  the closed notification is still a fact"
		FAILS=$((FAILS + 1))
	fi

	kill "$NSRV" 2>/dev/null
	rm -f "$NSOCK" "$NSOCK.state" "$NCONF"
else
	echo "skip  notify (no busctl or no session bus)"
fi

if [ -s "$SOCK.state" ]; then
	echo "ok    projection written"
else
	echo "FAIL  projection missing or empty"
	FAILS=$((FAILS + 1))
fi

[ "$FAILS" -eq 0 ] && echo "kippsrv ok" || echo "$FAILS failed"
exit "$FAILS"
