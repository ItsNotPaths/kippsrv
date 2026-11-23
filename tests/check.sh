#!/bin/sh
# Start the daemon on its own source files, talk to it with socat, check what
# comes back. socat is a first-class client, so the checks use nothing else.
set -u
cd "$(dirname "$0")/.."

TOP=/tmp/kippsrv-check.$$
FAILS=0
SERVERS=""

cleanup() { kill $SERVERS 2>/dev/null; rm -rf "/tmp/kippsrv-check.$$"; }
trap cleanup EXIT

# A kippsrv with XDG folders under $1, so nothing of the session is read. The
# kippbus built in build/ is the one its sources run.
# Source files go in $1/data/kippsrv/sources.d, the system folder, or
# $1/config/kippsrv/sources.d, the user's.
folders() {
	mkdir -p "$1/run" "$1/config/kippsrv/sources.d" "$1/data/kippsrv/sources.d"
}
start() {
	PATH="$PWD/build:$PATH" XDG_RUNTIME_DIR="$1/run" XDG_CONFIG_HOME="$1/config" XDG_DATA_HOME="$1/home" \
		XDG_DATA_DIRS="$1/data" build/kippsrv 2>"$1/err" &
	SERVERS="$SERVERS $!"
	sleep 0.4
}

# A shipped file with its own one-line sources taken out and the one given put in.
adapter() {
	grep -v '^source' "sources.d/$1"
	printf '%s\n' "$2"
}

# Lines that do not name a client are sent as client "check".
ask() {
	case "$1" in
	connect*|'') printf '%s' "$1" ;;
	*)           printf 'connect\tcheck\n%s' "$1" ;;
	esac | timeout 2 socat -t1 - UNIX-CONNECT:"$SOCK" 2>/dev/null
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
adapter wm-dwl.lua 'source { name = "wm", exec = "cat tests/fmt/dwl.txt",
         retains = {"tag/*", "focus", "layout/*", "title/*", "app/*"} }' > "$SYSTEM/wm-dwl.lua"

# A claim overlapping one already loaded refuses its file, and so does a taken
# name. Files load in name order, so a-owner is first.
echo 'source { name = "owner", retains = {"x/*"} }' > "$SYSTEM/a-owner.lua"
echo 'source { name = "greedy", exec = "true", retains = {"x/y/*"} }' > "$USER/b-greedy.lua"
echo 'source { name = "owner", exec = "true" }' > "$SYSTEM/c-twin.lua"

# The user's file replaces the system file of the same name.
echo 'source { name = "system-copy", exec = "true" }' > "$SYSTEM/d-same.lua"
echo 'source { name = "user-copy", exec = "true" }' > "$USER/d-same.lua"

# A request reaches the source that takes it, and its answer comes back as
# the source's own output.
cat > "$SYSTEM/f-echo.lua" <<'EOF2'
source { name = "echo", exec = "cat", takes = "echo/request", retains = "echo/*" }
function request(m)
	if not m.payload.word then return nil, "badarg", "word= is missing" end
	return "echo " .. m.payload.word .. "\n"
end
function feed(line)
	local word = line:match("^echo (%S+)$")
	if word then k.retain("echo/" .. word, "seen=1") end
end
EOF2

# A file with no request speaks kipp, so its source is sent the line as it is.
cat > "$SYSTEM/g-pass.lua" <<'EOF2'
source { name = "pass", takes = "pass/request", retains = "pass/*",
         exec = [[awk -F'\t' '{ print "retain\tpass/got\t" $3; fflush() }']] }
EOF2

# A retain outside the source's claim is dropped.
cat > "$SYSTEM/e-stray.lua" <<'EOF2'
source { name = "stray", exec = "echo go", retains = {"y/*"} }
function feed(line) k.retain("z/1", "a=b") end
EOF2

start "$TOP"

want greeting   'version	2	broker=kippsrv'   ''
want dump       'retain	tag/0/1	state=occupied' 'subscribe	*
'
want urgent     'retain	tag/0/4	state=occupied,urgent' 'subscribe	*
'
want_none emptied '^retain	tag/0/3'          'subscribe	*
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
want status     'retain	status/wm	state=online	retains=tag/\*,focus,' 'subscribe	status/*
'
if printf 'subscribe\t*\n' | timeout 2 socat -t1 - UNIX-CONNECT:"$SOCK" 2>/dev/null |
   grep -q 'error	noconnect'; then
	echo "ok    noconnect"
else
	echo "FAIL  noconnect (a line before connect was not refused)"
	FAILS=$((FAILS + 1))
fi
want no_forgery 'error	badtopic	topic=tag/0/9	msg=outside its claim' 'retain	tag/0/9	state=focused
'
want claimed    '^retain	x/1	v=1'          'connect	owner
subscribe	x/*
retain	x/1	v=1
'
ask 'connect	owner
will	retain	x/state	state=offline
' >/dev/null
want will       '^retain	x/state	state=offline' 'subscribe	x/*
'
want request    '^retain	echo/hi	seen=1'   'subscribe	echo/*
publish	echo/request	word=hi
'
want passthrough '^retain	pass/got	word=hi'  'subscribe	pass/*
publish	pass/request	word=hi
'
want request_refused 'error	badarg	topic=echo/request	msg=word= is missing' 'publish	echo/request
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

# D-Bus needs a live session bus and gdbus. Missing either is a skip. Each
# server owns a test name, never the real one: taking that stops whatever
# holds it, which is not a thing a test does.
if command -v gdbus >/dev/null && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	B=$TOP/bus
	folders "$B"
	SOURCES=$B/data/kippsrv/sources.d
	TRAY=org.kippsrv.CheckTray.p$$
	NOTIFY=org.kippsrv.CheckNotify.p$$
	NPATH=/org/freedesktop/Notifications
	NIFACE=org.freedesktop.Notifications

	# A request answered with a call line reaches the bus. This one registers
	# an item with the tray below, so the tray's fact shows the call arrived.
	{ cat <<EOF2
source { name = "match", retains = "sig/*", takes = "sig/request",
         exec = [[kippbus match "type='signal',interface='org.kippsrv.Test'"]] }
function request(m)
	return "call\t$TRAY\t/StatusNotifierWatcher\torg.kde.StatusNotifierWatcher\t" ..
	       "RegisterStatusNotifierItem\ts\torg.test.Called\n"
end
EOF2
	  cat tests/lua/dbus_echo.lua; } > "$SOURCES/match.lua"
	adapter tray-snw.lua "source { name = \"tray\", exec = \"kippbus tray $TRAY\",
         retains = \"tray/*\", takes = \"tray/request\" }" > "$SOURCES/tray-snw.lua"
	adapter notify-fdo.lua "source { name = \"notify\", exec = \"kippbus notify $NOTIFY\",
         retains = \"notif/*\", takes = \"notif/request\" }" > "$SOURCES/notify-fdo.lua"

	# A name already on the bus at start is called with --each, and one that
	# leaves takes its fact with it.
	NAMES=org.kippsrv.CheckNames.p$$
	sleep 10 | build/kippbus notify "$NAMES.one" &
	NAMED=$!
	cat > "$SOURCES/names.lua" <<EOF2
source { name = "names", retains = "named/*",
         exec = [[kippbus match --names $NAMES --each "$NPATH $NIFACE GetServerInformation"]] }
function feed(line)
	local message = k.json(line)
	if not message then return end
	if message.type == "left" then k.retain("named/one") end
	if message.type == "method_return" then k.retain("named/one", "server=" .. message.body[1].data) end
end
EOF2
	sleep 0.3
	start "$B"
	SOCK=$B/run/kippsrv.sock
	STATE=$B/run/kippsrv.state

	gdbus emit --session --object-path /x --signal org.kippsrv.Test.Sig \
		"'hello'" "{'k1': <'v1'>, 'k2': <42>}" >/dev/null 2>&1
	sleep 0.4
	# a variant is collapsed the way busctl collapses it, so one adapter
	# works whether a fact was polled or pushed
	if grep -q 's=hello	k1=v1	k2=42' "$STATE"; then
		echo "ok    a signal reaches the adapter as busctl's JSON"
	else
		echo "FAIL  the signal did not reach the adapter"
		FAILS=$((FAILS + 1))
	fi

	if grep -q '^retain	named/one	server=kippbus' "$STATE"; then
		echo "ok    a name on the bus at start is called with --each"
	else
		echo "FAIL  the --each reply did not reach the adapter"
		FAILS=$((FAILS + 1))
	fi
	kill $NAMED
	sleep 0.4
	if ! grep -q '^retain	named/' "$STATE"; then
		echo "ok    a name that leaves drops its fact"
	else
		echo "FAIL  the name left and its fact stayed"
		FAILS=$((FAILS + 1))
	fi

	gdbus call --session --dest "$TRAY" --object-path /StatusNotifierWatcher \
		--method org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem "'org.test.Item'" \
		>/dev/null 2>&1
	got=$(gdbus call --session --dest "$TRAY" --object-path /StatusNotifierWatcher \
		--method org.freedesktop.DBus.Properties.Get \
		"'org.kde.StatusNotifierWatcher'" "'RegisteredStatusNotifierItems'" 2>/dev/null)
	if printf '%s' "$got" | grep -q 'org.test.Item' &&
	   grep -q '^retain	tray/org.test.Item/StatusNotifierItem	state=registered' "$STATE"; then
		echo "ok    the tray owns a name and an item becomes a fact"
	else
		echo "FAIL  the tray did not register ($got)"
		FAILS=$((FAILS + 1))
	fi

	ask 'publish	sig/request
' >/dev/null
	sleep 0.4
	if grep -q '^retain	tray/org.test.Called/' "$STATE"; then
		echo "ok    a call line reaches the bus"
	else
		echo "FAIL  the call line did not reach the bus"
		FAILS=$((FAILS + 1))
	fi

	# The reply is the id, and the id is what everything else names.
	id=$(gdbus call --session --dest "$NOTIFY" --object-path "$NPATH" --method "$NIFACE.Notify" \
		"'grim'" "uint32 0" "'camera'" "'Screenshot saved'" "'body'" "@as []" \
		"{'urgency': <byte 2>}" "int32 0" 2>/dev/null | sed -n 's/^(uint32 \([0-9]*\),)$/\1/p')
	sleep 0.4
	line=$(grep '^retain	notif/' "$STATE" | head -1)
	if [ "$id" = "1" ] && printf '%s' "$line" | grep -q 'app=grim.*urgency=critical'; then
		echo "ok    Notify answers with an id, and a hint reaches the fact"
	else
		echo "FAIL  no usable notif fact ($id, $line)"
		FAILS=$((FAILS + 1))
	fi

	ask 'publish	notif/request	action=read
' >/dev/null
	sleep 0.4
	if grep '^retain	notif/' "$STATE" | grep -q 'read=1'; then
		echo "ok    a request reaches kippbus as kipp"
	else
		echo "FAIL  action=read left nothing read"
		FAILS=$((FAILS + 1))
	fi

	gdbus call --session --dest "$NOTIFY" --object-path "$NPATH" \
		--method "$NIFACE.CloseNotification" "uint32 ${id:-1}" >/dev/null 2>&1
	sleep 0.4
	if ! grep -q '^retain	notif/' "$STATE"; then
		echo "ok    closing one drops its fact"
	else
		echo "FAIL  the closed notification is still a fact"
		FAILS=$((FAILS + 1))
	fi
	SOCK=$TOP/run/kippsrv.sock
else
	echo "skip  bus (no gdbus or no session bus)"
fi

if [ -s "$TOP/run/kippsrv.state" ]; then
	echo "ok    projection written"
else
	echo "FAIL  projection missing or empty"
	FAILS=$((FAILS + 1))
fi

[ "$FAILS" -eq 0 ] && echo "kippsrv ok" || echo "$FAILS failed"
exit "$FAILS"
