#!/bin/sh
# Start the daemon on its own source files, talk to it with socat, check what
# comes back. socat is a first-class client, so the checks use nothing else.
set -u
cd "$(dirname "$0")"

TOP=/tmp/kippsrv-check.$$
FAILS=0
SERVERS=""

cleanup() { kill $SERVERS 2>/dev/null; rm -rf "/tmp/kippsrv-check.$$"; }
trap cleanup EXIT

# A kippsrv with XDG folders under $1, so nothing of the session is read.
# Source files go in $1/data/kippsrv/sources.d, the system folder, or
# $1/config/kippsrv/sources.d, the user's.
folders() {
	mkdir -p "$1/run" "$1/config/kippsrv/sources.d" "$1/data/kippsrv/sources.d"
}
start() {
	XDG_RUNTIME_DIR="$1/run" XDG_CONFIG_HOME="$1/config" XDG_DATA_DIRS="$1/data" \
		./kippsrv 2>"$1/err" &
	SERVERS="$SERVERS $!"
	sleep 0.4
}

# A shipped file with its own one-line sources taken out and the one given put in.
adapter() {
	grep -v '^source' "sources.d/$1"
	printf '%s\n' "$2"
}

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

said() {
	name=$1 pattern=$2
	if grep -q "$pattern" "$TOP/err"; then
		echo "ok    $name"
	else
		echo "FAIL  $name (stderr has no '$pattern')"
		FAILS=$((FAILS + 1))
	fi
}

folders "$TOP"
SYSTEM=$TOP/data/kippsrv/sources.d
USER=$TOP/config/kippsrv/sources.d
SOCK=$TOP/run/kippsrv.sock

# The source ends long before the consumer connects. Everything the consumer
# sees comes out of the store.
adapter wm-dwl.lua 'source { name = "wm", exec = "cat test/fmt/dwl.txt",
         retains = {"tag/*", "focus/*", "layout/*", "title/*", "app/*"} }' > "$SYSTEM/wm-dwl.lua"

# A claim overlapping one already loaded refuses its file, and so does a taken
# name. Files load in name order, so a-owner is first.
echo 'source { name = "owner", retains = {"x/*"} }' > "$SYSTEM/a-owner.lua"
echo 'source { name = "greedy", exec = "true", retains = {"x/y/*"} }' > "$USER/b-greedy.lua"
echo 'source { name = "owner", exec = "true" }' > "$SYSTEM/c-twin.lua"

# The user's file replaces the system file of the same name.
echo 'source { name = "system-copy", exec = "true" }' > "$SYSTEM/d-same.lua"
echo 'source { name = "user-copy", exec = "true" }' > "$USER/d-same.lua"

# A retain outside the source's claim is dropped.
cat > "$SYSTEM/e-stray.lua" <<'EOF2'
source { name = "stray", exec = "echo go", retains = {"y/*"} }
function feed(line) k.emit("z", "1", "a=b") end
EOF2

start "$TOP"

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
want_none unsubscribed '^publish'           'subscribe	key/*
unsubscribe	key/*
publish	key/x
'
want_none unheard '^publish'                'publish	key/x
'

said claim_refused   'b-greedy.lua was not loaded: .*a-owner.lua already claims'
want_none claim_gone 'status/greedy'        'subscribe	status/*
'
said name_refused    'c-twin.lua was not loaded: .*a-owner.lua already names a source "owner"'
want user_file       'status/user-copy'     'subscribe	status/*
'
want_none system_file 'status/system-copy'  'subscribe	status/*
'
said outside_claim   'source "stray" retained "z/1", outside its claim'
want_none stray_dropped '^retain	z/'        'subscribe	*
'

# (hole requests) the v1 command seam is gone; v2 requests bring its check back.
echo "skip  commands (v2 requests are not built)"

# D-Bus needs a live session bus and busctl. Missing either is a skip.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	D=$TOP/dbus
	folders "$D"
	{ echo "source { name = \"test\", retains = \"*\",
         dbus = {\"type='signal',interface='org.kippsrv.Test'\"} }"
	  cat test/lua/dbus_echo.lua; } > "$D/data/kippsrv/sources.d/test.lua"
	start "$D"
	DSOCK=$D/run/kippsrv.sock
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
	rm -f /tmp/kippsrv-dbus.$$.out
else
	echo "skip  dbus (no busctl or no session bus)"
fi

# The watcher owns a test name, never the real one. Taking
# org.kde.StatusNotifierWatcher stops whatever holds it, which is not a thing
# a test does.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	W=$TOP/watcher
	WNAME=org.kippsrv.CheckWatcher.p$$
	folders "$W"
	adapter tray-snw.lua "source { name = \"watcher\", watcher = true, bus_name = \"$WNAME\",
         retains = \"tray/*\" }" > "$W/data/kippsrv/sources.d/tray-snw.lua"
	start "$W"
	WSOCK=$W/run/kippsrv.sock
	busctl --user call "$WNAME" /StatusNotifierWatcher \
		org.kde.StatusNotifierWatcher RegisterStatusNotifierItem s org.test.Item \
		>/dev/null 2>&1
	got=$(busctl --user get-property "$WNAME" /StatusNotifierWatcher \
		org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems 2>/dev/null)
	tray=$(grep -c '^retain	tray/' "$W/run/kippsrv.state" 2>/dev/null || echo 0)
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
else
	echo "skip  watcher (no busctl or no session bus)"
fi

# The notification server owns a test name, never org.freedesktop.Notifications.
# Taking that one stops whatever holds it, which is not a thing a test does.
if command -v busctl >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	N=$TOP/notify
	NNAME=org.kippsrv.CheckNotify.p$$
	NPATH=/org/freedesktop/Notifications
	NIFACE=org.freedesktop.Notifications
	folders "$N"
	# The tray loads first on purpose: files load in name order. Every D-Bus
	# source is offered the servers' state, and a notification must still
	# reach only its own adapter.
	adapter tray-snw.lua "source { name = \"tray\", watcher = true, bus_name = \"$NNAME.w\",
         retains = \"tray/*\" }" > "$N/data/kippsrv/sources.d/a-tray.lua"
	adapter notify-fdo.lua "source { name = \"notify\", notify = true, bus_name = \"$NNAME\",
         retains = \"notif/*\" }" > "$N/data/kippsrv/sources.d/b-notify.lua"
	start "$N"
	NSTATE=$N/run/kippsrv.state

	# The reply is the id, and the id is what everything else names.
	id=$(busctl --user call "$NNAME" "$NPATH" "$NIFACE" Notify \
		'susssasa{sv}i' grim 0 camera "Screenshot saved" body 0 1 urgency y 2 0 \
		2>/dev/null | awk '{print $2}')
	sleep 0.4
	line=$(grep '^retain	notif/' "$NSTATE" 2>/dev/null | head -1)

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
	if grep '^retain	notif/' "$NSTATE" 2>/dev/null | grep -q 'read=1'; then
		echo "ok    a notification can be marked read"
	else
		echo "FAIL  MarkAllRead left nothing read"
		FAILS=$((FAILS + 1))
	fi

	busctl --user call "$NNAME" "$NPATH" "$NIFACE" \
		CloseNotification u "${id:-1}" >/dev/null 2>&1
	sleep 0.4
	if ! grep -q '^retain	notif/' "$NSTATE" 2>/dev/null; then
		echo "ok    closing one drops its fact"
	else
		echo "FAIL  the closed notification is still a fact"
		FAILS=$((FAILS + 1))
	fi
else
	echo "skip  notify (no busctl or no session bus)"
fi

if [ -s "$TOP/run/kippsrv.state" ]; then
	echo "ok    projection written"
else
	echo "FAIL  projection missing or empty"
	FAILS=$((FAILS + 1))
fi

[ "$FAILS" -eq 0 ] && echo "kippsrv ok" || echo "$FAILS failed"
exit "$FAILS"
