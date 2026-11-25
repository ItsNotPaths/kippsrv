# kippsrv how-to

How to run kippsrv, read from it, and add your own sources. The binary carries
this file: `kippsrv howto` prints it, and `kippsrv howto <word>...` prints only
the parts about those words, such as `kippsrv howto claim` or
`kippsrv howto bluetooth`. [README.md](README.md) explains why it is built this
way. [DIAGNOSTICS.md](DIAGNOSTICS.md) explains every message with a
code in brackets.

1. [Install and run](#1-install-and-run)
2. [kipp lines](#2-kipp-lines)
3. [Read from kippsrv](#3-read-from-kippsrv)
4. [Write a source file](#4-write-a-source-file)
5. [Write an adapter](#5-write-an-adapter)
6. [Take requests](#6-take-requests)
7. [Connect your own program](#7-connect-your-own-program)
8. [D-Bus sources](#8-d-bus-sources)
9. [When something is wrong](#9-when-something-is-wrong)

## 1. Install and run

<!-- howto: install installing installed --install build building builds build.sh download-deps.sh deps dependencies requirements odin compiler git meson ninja gperf basu d-bus dbus library kippbus clone compile sudo prefix destdir /usr/local /usr/local/bin .local ~/.local/bin bin package packaging setup missing update upgrade version --version uninstall uninstalling --uninstall remove removing delete nuke clean -->

You need the [Odin](https://odin-lang.org) compiler, git, and meson, ninja and
gperf. `download-deps.sh` checks for them and says which are missing, then
clones basu, the D-Bus library kippbus links, from git.sr.ht and builds it.

```sh
./download-deps.sh
./build.sh
build/kippsrv --install
```

`kippsrv --install` puts `kippsrv` and `kippbus` in `~/.local/bin`, and writes
the shipped source files, which are built into the binary, to
`~/.local/share/kippsrv/sources.d/`. Running it again replaces both, so it is
also how to update. `kippsrv --version` says which build you have.

`kippsrv --uninstall` removes every file of kippsrv: both binaries, the
shipped source files, your own in `~/.config/kippsrv`, the state file, and a
system install under `$XDG_DATA_DIRS` (that one needs sudo). It refuses while
kippsrv runs.

A package installs system-wide instead:
`PREFIX=/usr DESTDIR=pkg ./build.sh install --version vX.Y.Z`.

<!-- howto: run running start starting startup launch kippsrv daemon service autostart foreground background stderr log logs logging session window manager wm bar config arguments sigint sigterm stop stopping quit kill signal -->

Run `kippsrv` with no arguments. It stays in the foreground and logs to
stderr, so start it from your session's autostart (your window manager's
config, or whatever runs your bar). It stops on SIGINT or SIGTERM.

<!-- howto: xdg_runtime_dir runtime socket sock kippsrv.sock kippsrv.state state file files path location where scripts values rewritten one instance single second another already running exits exit in use duplicate -->

It needs `XDG_RUNTIME_DIR`, and puts two files there:

| File | Holds |
| --- | --- |
| `kippsrv.sock` | the socket that clients connect to |
| `kippsrv.state` | every current value, for scripts that will not hold a connection. Rewritten when a value changes, at most four times a second |

Only one kippsrv runs per `XDG_RUNTIME_DIR`. A second one finds the socket in
use and exits.

### Where source files live

<!-- howto: config configuration configure settings source sources source-file sources.d .lua lua folder folders directory directories xdg_config_home xdg_data_home xdg_data_dirs .config/kippsrv/sources.d .config .local/share /usr/share /usr/local/share where location path override overrides copy edit change customize disable turn off comment shipped order restart reload -->

There is no config file. Each source lives in a `.lua` file, and kippsrv looks
in these folders, first one first:

1. `$XDG_CONFIG_HOME/kippsrv/sources.d/` (by default `~/.config/kippsrv/sources.d/`):
   yours
2. `$XDG_DATA_HOME/kippsrv/sources.d/` (by default `~/.local/share/kippsrv/sources.d/`):
   what `kippsrv --install` wrote
3. `kippsrv/sources.d/` in each folder of `$XDG_DATA_DIRS` (by default
   `/usr/local/share` then `/usr/share`): a system install

The first folder that holds a file name wins. So to change a shipped file,
copy it into `~/.config/kippsrv/sources.d/` under the same name and edit the
copy. To turn a shipped file off, copy it the same way and comment out its
`source{}` lines. kippsrv reads the files once at start, in name order:
restart it after a change.

### What ships

<!-- howto: shipped ships included bundled list default sources topics needs on off enable enabled disabled audio-pw.lua audio pipewire pulseaudio pactl sink volume sound backlight-brightnessctl.lua backlight brightness brightnessctl bt-bluez.lua bluetooth bluez headphones media-mpris.lua mpris media music player spotify firefox net-nm.lua network networkmanager nmcli wifi tray-snw.lua tray systray notify-fdo.lua notifications notification notify daemon wm-hypr.lua hyprland hypr wm-sway.lua sway i3 wm-dwl.lua dwl window manager wm power-upower.lua power battery upower -->

| File | Topics | Needs | On |
| --- | --- | --- | --- |
| `audio-pw.lua` | `sink/<name>` | `pactl` | yes |
| `backlight-brightnessctl.lua` | `backlight/<device>` | `brightnessctl` | yes |
| `bt-bluez.lua` | `bt/<address>`, `bt_radio/<id>` | bluez on the system bus | yes |
| `media-mpris.lua` | `media/<player>` | an MPRIS media player | yes |
| `net-nm.lua` | `net/<uuid>` | `nmcli` (NetworkManager) | yes |
| `tray-snw.lua` | `tray/<item>` | nothing; kippbus becomes the tray watcher | yes |
| `notify-fdo.lua` | `notif/<id>` | no other notification daemon running | no |
| `wm-hypr.lua` | `focus`, `mode`, `tags/...`, `tag/...`, `layout/...`, `title/...`, `app/...` | Hyprland | no |
| `wm-sway.lua` | the same | sway or i3 | no |
| `wm-dwl.lua` | the same | dwl | no |
| `power-upower.lua` | `power/<device>` | `upower` | yes |

The window manager files are off because only one of them fits your session.
Copy that one and uncomment its sources. `notify-fdo.lua` is off because only
one program can be the notification daemon: turn it on only when no other one
runs.

<!-- howto: missing command not installed offline down fail failed fails source sources carry on fields field topic topics subscribe -->

A source whose command is missing goes offline (section 3 shows how to see
that) and the rest carry on. To see the fields a topic carries, subscribe to it.

## 2. kipp lines

<!-- howto: kipp protocol format version mqtt line lines message messages text tab tabs fields example retain topic payload verb wire syntax -->

kippsrv speaks [kipp](https://github.com/ItsNotPaths/kipp) version 2. kipp
takes MQTT's model and writes it as text: one message per line, fields
separated by tabs.

```
retain	media/firefox/instance_1_719	status=Paused	title=Home / X	artist=	length=17
```

That line is a verb (`retain`), a topic (`media/firefox/instance_1_719`), and
four payload fields.

<!-- howto: verb verbs retain publish value event topic topics kind name naming rules rule valid invalid characters allowed lowercase digits underscore payload field fields key keys values equals split delete deleting remove clear empty 1024 bytes limit length maximum size -->

- **The verb** says what the line is. `retain` is a value: the latest one per
  topic is kept. `publish` is an event: passed on, never kept.
- **The topic** names a thing. Its first part, up to the first `/`, is its
  kind: lowercase letters, digits and underscores, never only digits. The rest
  may hold anything except control characters and `*`, `?` and `[`.
- **The payload** is `key=value` fields. A key follows the same rule as a
  kind. A value runs to the end of its field, and only the first `=` splits
  it, so `name=home=wifi` is the key `name` with the value `home=wifi`.
- **`delete` removes** the topic's value, and has no payload. A `retain` always
  has a field; one with none is refused with `error badarg`.
- **A line holds at most 1024 bytes.**

<!-- howto: version sync error errors refused refuse rejected broker first line lines kippsrv sends code codes server reply replies response connection -->

kippsrv sends these lines of its own:

| Line | Means |
| --- | --- |
| `version	2	broker=kippsrv` | the first line on every connection |
| `sync	<pattern>` | the current values for a subscription have all been sent |
| `error	<code>	...	msg=<text>` | something you sent was refused |

## 3. Read from kippsrv

<!-- howto: read reading connect connection subscribe subscribing client consumer bar socat shell example sync first frame values current changes watch listen stream status online quickstart -->

Connect to the socket, send `connect <name>`, then `subscribe <pattern>`.
A shell does it with `socat`:

```sh
(printf 'connect\tme\nsubscribe\t*\n'; cat) | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/kippsrv.sock"
```

```
version	2	broker=kippsrv
retain	status/bt	state=online	retains=bt/*,bt_radio/*
retain	status/media	state=online	retains=media/*
retain	media/firefox/instance_1_719	status=Paused	title=Home / X	artist=	length=17
sync	*
```

After `subscribe`, kippsrv sends every current value the pattern matches, then
`sync <pattern>`, then each change as it happens. A bar draws its first frame
at `sync`.

<!-- howto: commands command verbs send connect name subscribe unsubscribe retain publish will request event replace replaces same name duplicate drop disconnect -->

| You send | It does |
| --- | --- |
| `connect	<name>` | names this connection. Must come first. A second connection with the same name replaces the first |
| `subscribe	<pattern>` | current values, `sync`, then changes |
| `unsubscribe	<pattern>` | stops that pattern |
| `retain	<topic>	...` | a value of your own (section 7) |
| `publish	<topic>	...` | an event or a request (section 6) |
| `will	retain ...` or `will	publish ...` | a line kippsrv sends for you when your connection drops (section 7) |

<!-- howto: pattern patterns glob globs wildcard wildcards match matching matches fnmatch * star slash filter topics media/* firefox spotify instance instances -->

Patterns are matched like shell globs, with `fnmatch(3)`, and `*` crosses `/`.
`media/*` matches `media/spotify` and `media/firefox/instance_1_719`.
`media/firefox/*` matches only firefox instances.

<!-- howto: status status/* running alive online offline state source sources dead died dies crash crashed stale last-known last known retains claim grey gray headphone disconnected down gone health check -->

**Is a source running?** For each source it runs, kippsrv retains
`status/<source name>` with `state=online` or `state=offline`, and the
source's claim as `retains=<patterns>`. A source that dies keeps its last
values: subscribe to `status/*` and match your topics against `retains=` to
know which values are last-known. A bar can then grey out a headphone instead
of claiming it is gone.

<!-- howto: slow stops reading consumer queue queued full buffer 256 kb disconnect disconnected disconnects dropped kicked backpressure reconnect resubscribe lag -->

**A consumer that stops reading** has 256 KB of lines queued for it. When the
queue fills, kippsrv disconnects it. Connect and subscribe again to get the
current values.

<!-- howto: scripts script state file kippsrv.state read value now once cat snapshot dump current values no connection shell xdg_runtime_dir rate -->

**Scripts** that only need a value now can read `$XDG_RUNTIME_DIR/kippsrv.state`:
it holds the same `retain` lines a `subscribe *` would send, replaced as a whole
when a value changes, at most four times a second.

## 4. Write a source file

<!-- howto: write writing new source sources file example create add adding custom own battery battery-sys.lua sys capacity exec every feed k.retain retain retains poll polling command interval seconds tutorial first -->

A source file declares sources with `source{}`, and holds the adapter that
turns their output into kipp. Here is a whole one. Save it as
`~/.config/kippsrv/sources.d/battery-sys.lua` and restart kippsrv:

```lua
source { name = "battery", exec = "cat /sys/class/power_supply/BAT0/capacity", every = 30000,
         retains = "battery/*" }

function feed(line)
	k.retain("battery/BAT0", "percent=" .. line)
end
```

kippsrv runs the command every 30 seconds and hands each line of its output
to `feed`. `feed` retains one value. A subscriber to `battery/*` gets
`retain battery/BAT0 percent=100`, and then a new line only when the number
changes.

### `source{}` fields

<!-- howto: source fields field options option name exec sock socket timer tick every retains takes throttle stdout stdin sh unix dial redial reconnect interval ms milliseconds period once command syntax claim-only claim -->

| Field | Means |
| --- | --- |
| `name` | the source's name, unique across all files. It names `status/<name>` too |
| `exec` | a command, run through `sh -c`. Its stdout comes to `feed`; its stdin takes requests (section 6) |
| `sock` | a unix socket path to connect to. Its lines come to `feed`. Dialled again every 2 seconds while closed. `$VAR` is expanded |
| `timer = true` | no command at all: call the file's `tick` every `every` ms |
| `every` | ms. An `exec` that ends runs again this long after. Without it, the command runs once |
| `retains` | the topics this source may retain: one pattern, or a list |
| `takes` | the request topics this source answers (section 6) |
| `throttle` | slows the source down; see below |

A source sets one of `exec`, `sock` or `timer`. A source with none of them is a
claim only: it lets a program of that name retain those topics itself
(section 7).

### Claims

<!-- howto: claim claims claimed owner ownership own retains e-claim dropped refused refuse refusal overlap overlapping conflict conflicts collide clash duplicate name same file files earlier later share comma commas patterns load loading loaded -->

`retains` is the source's claim. Each topic has one owner:

- A retain outside the claim is dropped, and kippsrv logs `[E-claim]` once
  for that source.
- If a file claims a pattern that could name the same topic as a pattern an
  earlier file claims (either one matches the other), the later file is
  refused whole, and the message names both files.
- A source name already used by an earlier file refuses the later file the
  same way.
- Sources in one file may share a claim. That is how a seed and a stream for
  one window manager work.
- A pattern in a claim cannot contain a comma, because `status/<name>` lists
  the claim with commas between the patterns.

### Several sources, one file

<!-- howto: several multiple sources one file seed stream event events socket hyprland hypr wm-hypr.lua hyprctl monitors json socket2 locals shared state share combine initial startup current focus window manager wm apart -->

A file is loaded once however many sources it declares, and its locals live
as long as its sources. So several sources can build one picture together.

An event stream reports what changed, not what is, so an adapter that has seen
no events knows nothing. So the file adds a second source that reads the
current state once, a seed. `wm-hypr.lua` has both:

```lua
local claim = {"focus", "mode", "tags/*", "tag/*", "layout/*", "title/*", "app/*"}
source { name = "wm-seed", exec = "hyprctl monitors -j", retains = claim }
source { name = "wm", sock = "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock",
         retains = claim }
```

`hyprctl monitors -j` tells the file which monitor is focused, and the
socket's events are resolved against it. `feed` is not told which source a line
came from: this file tells them apart by shape, because `hyprctl` prints JSON
and socket2 prints `event>>data`.

### Throttling

<!-- howto: throttle throttling throttled poll polling slow slower slowed backoff period doubled double doubling idle quiet nothing new reset sixteen minute every interval delay -->

A poll that finds nothing new for three runs in a row has its period doubled,
up to sixteen times `every` or a minute, whichever is smaller. A poll finds
something new when a line it produced changed a value. Anything new resets the
period.

<!-- howto: throttle false disable off volume key brightness keypress press lag slow delay responsive audio-pw.lua backlight-brightnessctl.lua person driven -->

`throttle = false` turns that off. Use it for anything a person drives: a poll
every 2 seconds can stretch to 32, so a volume key press could take that long
to show. `audio-pw.lua` and
`backlight-brightnessctl.lua` are both `throttle = false`.

<!-- howto: throttle table idle factor ceiling defaults default settings tune tuning cap ms multiply doubling -->

`throttle` can also be a table. The defaults are
`throttle = { idle = 3, factor = 16, ceiling = 60000 }`: quiet runs before
doubling, the most `every` may be multiplied by, and a cap in ms.

<!-- howto: min_gap gap rate limit limiting debounce sock socket stream exec never ends drop dropped lines newest events lost flood spam busy ms -->

A `sock` source, or an `exec` that never ends, has no period to stretch.
`throttle = { min_gap = 250 }` slows it the other way: `feed` runs at most once
per 250 ms, with the newest line, and the lines between are dropped. Only use
it when each line restates the current value. A dropped event is gone.

## 5. Write an adapter

<!-- howto: adapter adapters function functions callback callbacks feed flush tick request line lines newline blank exec exited sock closed timer hook hooks handler handlers -->

The functions a file defines are its adapter. All are optional.

| Function | Called |
| --- | --- |
| `feed(line)` | with each line a source produced, without its newline. Blank lines are skipped |
| `flush()` | when a source's output ends: an `exec` exited, or a `sock` closed |
| `tick()` | every `every` ms, for a `timer = true` source |
| `request(message, source_name)` | when a request reaches a source of this file (section 6) |

<!-- howto: k api k.retain k.delete k.publish k.json k.parse k.log retain publish json parse decode decoding log logging print debug store stored delete event calls call nil table tables -->

An adapter calls into kippsrv through `k`:

| Call | Does |
| --- | --- |
| `k.retain(topic, "key=value", ...)` | a value. Stored, and passed on when it changed. Needs a field |
| `k.delete(topic)` | the value is gone. Forgotten, and passed on |
| `k.publish(topic, "key=value", ...)` | an event. Passed on, never stored |
| `k.json(text)` | decodes JSON into tables, or returns `nil` |
| `k.parse(line)` | decodes a kipp line into `{verb, topic, payload}`, or returns `nil` |
| `k.log(...)` | writes to kippsrv's stderr. `print` does the same |

<!-- howto: valid invalid kipp e-word e-toolong e-full dropped drop too long 1024 bytes store limit 4096 topics full maximum cap errors error rejected -->

A line an adapter builds must be valid kipp (section 2). One that is not is
dropped with `[E-word]`, and one over 1024 bytes with `[E-toolong]`. The store
holds at most 4096 topics. Past that, a retain to a new topic is dropped and
kippsrv logs `[E-full]` once; topics it already holds still update.

### A file with no `feed`

<!-- howto: no feed passthrough pass through raw kipp program prints tray-snw.lua tray kippbus claim unchanged -->

A file with no `feed` is for a program that already prints kipp. Its
`retain` and `publish` lines pass through unchanged, still held to the claim.
`tray-snw.lua` works this way: `kippbus tray` prints kipp itself.

### Keeping state

<!-- howto: state keep keeping locals local variables memory accumulate record records multiline multi-line many lines flush upower power power-upower.lua battery device end output -->

Locals live as long as the file's sources, so an adapter can build a value
over many lines. `upower -i` prints one device as an indented record over many
lines, with nothing to mark the end of the last one. `power-upower.lua` keeps
the fields it has seen in locals, and retains the device in `flush`, when the
output ends.

### The sandbox

<!-- howto: sandbox sandboxed security io os require files file open command commands network forbidden not allowed missing limit limits instructions memory 64 mb vm lua error errors crash timeout infinite loop -->

An adapter cannot open files, run commands or reach the network: `io`, `os`,
`require` and their kind do not exist. Its source does that work. Each call
may run about 2 million Lua instructions and the VM may hold 64 MB. A call that
errors or runs past a limit is logged as `lua: <function>: <error>`, its output
is lost, and kippsrv carries on.

## 6. Take requests

<!-- howto: request requests take takes taking publish command commands control action actions send sending match matches topic file decides return returns string nil code text table error message message.payload message.topic payload k.parse forward forwarding -->

A request is a `publish`. It goes to every subscriber, like any publish, and to
every source whose `takes` matches its topic. kippsrv never learns what a
request means: the file decides.

| The file has | The source gets |
| --- | --- |
| no `request` | the request line as it is |
| a `request` that returns a string | those bytes |
| a `request` that returns nothing | nothing |
| a `request` that returns `nil, code, text` | nothing, and the sender gets `error <code> topic=<topic> msg=<text>` |

`request(message, source_name)` gets the request as `k.parse` would return it:
`message.topic`, and `message.payload.<key>` for each field.

<!-- howto: stdin input bytes exec sock socket connection running poll exited request requests ignored lost nothing happens -->

The bytes go to an `exec` source's stdin, or down a `sock` source's
connection. So a source that takes requests must be running when one comes: a
poll that has already exited cannot take one.

<!-- howto: e-cmdemit request requests retain publish k.retain k.publish dropped emit facts values change action state reply response -->

A request makes no facts of its own. If `request` calls `k.retain` or
`k.publish`, the lines are dropped with `[E-cmdemit]`. The values that change after the action show
what it did.

<!-- howto: example request requests echo brightness brightnessctl backlight screen percent shell loop while read badarg error errors validate validation argument arguments tonumber socat publish test -->

Here is a file that takes a request and hands it to a shell loop. Change the
`echo` to `brightnessctl -q set "$percent%"` and it sets the screen
brightness:

```lua
source { name = "echo", exec = [[while read -r percent; do echo "$percent" >> /tmp/got; done]],
         takes = "echo/request" }

function request(message)
	local percent = tonumber(message.payload.percent)
	if not percent then return nil, "badarg", "percent= takes a number" end
	return percent .. "\n"
end
```

```sh
printf 'connect\tme\npublish\techo/request\tpercent=40\npublish\techo/request\tpercent=lots\n' |
	socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/kippsrv.sock"
```

```
version	2	broker=kippsrv
error	badarg	topic=echo/request	msg=percent= takes a number
```

`/tmp/got` now holds `40`. Section 8 lists the requests the shipped D-Bus
sources take.

## 7. Connect your own program

<!-- howto: own program programs client clients connect publish retain claim claims claim-only source name retains external app application script weather speak kipp without adapter producer -->

A program that speaks kipp needs no adapter. It connects to the socket and
publishes. A plain `publish` needs nothing more. To `retain`, it needs a claim,
and claims live in source files: a source with only `name` and `retains`.

```lua
-- ~/.config/kippsrv/sources.d/weather.lua
source { name = "weather", retains = "weather/*" }
```

<!-- howto: will wills last disconnect disconnected disconnects drop drops dropped connection exit crash stale cleanup delete value weather temperature example socat retain -->

A program that connects as `weather` may now retain `weather/*`. A `will`
says what kippsrv should send when the program's connection drops. Here the
will deletes the value, so a subscriber never sees a stale temperature:

```sh
printf 'connect\tweather\nwill\tdelete\tweather/home\nretain\tweather/home\ttemp=12\n' |
	socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/kippsrv.sock"
```

A subscriber to `weather/*` sees:

```
retain	weather/home	temp=12
sync	weather/*
delete	weather/home
```

The last line is the will: the program disconnected, and the value is gone.

<!-- howto: badtopic error outside claim refused rejected status no claim-only will gone -->

A retain outside the claim comes back as
`error badtopic topic=<topic> msg=outside its claim`.

kippsrv runs nothing for a claim-only source, so it has no `status/<name>`
topic. A will is how a program says it is gone.

## 8. D-Bus sources

<!-- howto: kippbus d-bus dbus bus usage commands command match tray notify system session --system --names --each name testing test live -->

kippsrv does not speak D-Bus. `kippbus` does, and a source file runs it like
any other command:

```
kippbus match [--system] [--names <namespace> [--each <call>]] <rule>...
kippbus tray [<name>]
kippbus notify [<name>]
```

`<name>` makes tray or notify own a different bus name, for testing beside a
live one.

### `kippbus match`

<!-- howto: kippbus match rule rules signal signals json busctl dbus-monitor session system --system body variant dictionary object k.json properties propertieschanged decode output format -->

`kippbus match` connects to the session bus, or the system bus with
`--system`, and prints each message its match rules take as one line of JSON.
Match rules are the strings `busctl` and `dbus-monitor` take.

```json
{"type":"signal","sender":":1.719","name":"org.mpris.MediaPlayer2.firefox.instance_1_719",
 "path":"/org/mpris/MediaPlayer2","interface":"org.freedesktop.DBus.Properties",
 "member":"PropertiesChanged","body":[...]}
```

Each value in `body` is `{"type": ..., "data": ...}`, as `busctl --json=short`
prints it. A variant is unwrapped to the value it holds. A dictionary becomes a
JSON object. `k.json` turns the line into tables.

### Tracking bus names

<!-- howto: names name track tracking --names --each namespace appeared left gone retract seed method_return call startup initial getall existing exists bus -->

Signals say what changed. An adapter needs what exists. `--names <namespace>`
makes kippbus track the bus names under that namespace:

| Line | Means |
| --- | --- |
| `{"type":"appeared","name":...}` | the name was on the bus at start, or arrived since |
| `{"type":"left","name":...}` | the name is gone; retract its values |
| `"name"` on every message | the watched name its sender owns, or `""` |

`--each <call>` calls each name as it appears. The call is the path,
interface, member, then the signature and arguments if any, separated by
spaces. The reply comes as a `{"type":"method_return", ...}` line, in order
with the signals, so the adapter needs no separate seed source.

<!-- howto: media-mpris.lua mpris media music player players spotify firefox namespace getall propertieschanged instance windows topic quit quits delete org.mpris.mediaplayer2 example -->

`media-mpris.lua` uses both:

```lua
local NAMESPACE = "org.mpris.MediaPlayer2"
local GET_ALL   = "/org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties GetAll s org.mpris.MediaPlayer2.Player"
local CHANGED   = "type='signal',interface='org.freedesktop.DBus.Properties'," ..
                  "member='PropertiesChanged',path='/org/mpris/MediaPlayer2'"
source { name = "media", retains = "media/*",
         exec = ('kippbus match --names %s --each "%s" "%s"'):format(NAMESPACE, GET_ALL, CHANGED) }
```

That runs one command:

```
kippbus match --names org.mpris.MediaPlayer2 --each "/org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties GetAll s org.mpris.MediaPlayer2.Player" "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/mpris/MediaPlayer2'"
```

Each player's bus name becomes its topic:
`org.mpris.MediaPlayer2.firefox.instance_1_719` is
`media/firefox/instance_1_719`, so two firefox windows are two topics. When a
player quits, `left` arrives and the file deletes its topic.

### Calling D-Bus

<!-- howto: call calling calls method methods d-bus dbus destination path interface member signature argument arguments types array dictionary struct container stdin request reply send -->

A request goes back out as a call line on kippbus's stdin, which `request`
returns as a string. Fields are separated by tabs:

```
call	<destination>	<path>	<interface>	<member>	<signature>	<argument>...
```

Arguments are text, and each character of the signature says how to send one:
`s`, `o`, `g`, `b`, `y`, `i`, `u`, `x`, `t` or `d`. A container (an array, a
dictionary, a struct) cannot be sent. No reply is asked for: the values that
change after the call show what it did.

<!-- howto: bt-bluez.lua bluetooth bluez bt headphones connect disconnect pair pairing forget scan scanning radio adapter address addr device devices bt/request requests control -->

`bt-bluez.lua` builds these lines from its requests:

```
publish	bt/request	action=connect|disconnect|pair|forget	addr=<address>
publish	bt/request	action=scan	state=on|off	radio=<id>
```

`radio=` is optional and picks a radio when there is more than one.

### `kippbus tray` and `kippbus notify`

<!-- howto: kippbus tray notify own owner bus name passthrough no feed request both ways -->

These own a bus name and print kipp themselves, so their files have no `feed`
and no `request`, and kipp passes through both ways.

<!-- howto: tray systray statusnotifierwatcher snw sni statusnotifier icon icons applet applets app application click left middle right activate secondary menu scroll wheel delta x y tray/request startup order start before missing empty pixmap tga dbusmenu menu entry entries submenu checkbox radio separator open click aboutToShow -->

`kippbus tray` owns `org.kde.StatusNotifierWatcher`. A tray application looks
for it once, when the application starts, so start kippsrv before them. Each
icon is a fact, deleted when the icon goes, and so is each entry of its menu:

```
retain	tray/<bus name>/<path>	state=registered	icon=	icon_path=	pixmap=	title=	status=	is_menu=0|1
retain	tray/<bus name>/<path>/menu/<id>	parent=	position=	label=	enabled=0|1	kind=standard|separator	toggle=none|check|radio	state=0|1	submenu=0|1
```

`icon=` is a name from the icon theme, looked up in `icon_path=` first when the
application gives one. `pixmap=` is a TGA file under
`$XDG_RUNTIME_DIR/kippbus/tray`, for applications that send pixels instead of a
name; each new picture is a new file, and the old one is removed. `is_menu=1`
means the application wants a left click to show its menu. A menu entry's
`parent=` is 0 at the top level, `position=` orders it among its siblings, and
hidden entries are left out. It takes:

```
publish	tray/request	action=activate|secondary|menu	item=<bus name>/<path>	x=<x>	y=<y>
publish	tray/request	action=scroll	item=<bus name>/<path>	delta=<steps>	dir=vertical|horizontal
publish	tray/request	action=open|click	item=<bus name>/<path>	entry=<id>
```

`activate` is a left click, `secondary` a middle click and `menu` a right
click, for the few applications that draw their own menu. `x=` and `y=` are
where on the screen, so the application can place a menu there. Send `open`
before a menu or submenu shows, with `entry=0` for the top level, since some
applications fill a menu only then; `click` runs an entry.

<!-- howto: notify notifications notification notify-send daemon dunst mako org.freedesktop.notifications notif notif/request summary body urgency read unread mark close dismiss clear action actions exec x-kipp-exec hint click clicked app icon id -->

`kippbus notify` owns `org.freedesktop.Notifications`, so `notify-send` and
every application's notifications come to it. Each one is

```
retain	notif/<id>	app=	summary=	body=	icon=	urgency=low|normal|critical	read=0|1	action=	exec=
```

`action=` is the key of the notification's first action. `exec=` is a command
the sender attached as the `x-kipp-exec` hint, for a bar to run when the
notification is clicked: it still works after the sender has exited, which
`notify-send` always has. kippbus does not send an action back to the
application that sent it. It takes:

```
publish	notif/request	action=close	id=<id>
publish	notif/request	action=read
```

`action=read` marks everything live as `read=1`.

## 9. When something is wrong

<!-- howto: wrong broken problem problems troubleshoot troubleshooting debug debugging error errors stderr log logs diagnostics diagnostics.md code codes e-claim config lua status status/* running k.log loaded load loading refused serving sources not working missing help -->

- **Read stderr.** kippsrv and kippbus log there. A message with a code in
  brackets, like `[E-claim]`, is explained in [DIAGNOSTICS.md](DIAGNOSTICS.md),
  with who can fix it.
- **Messages starting `config:`** are about a source in a source file, and
  name it.
- **`lua: ...`** is an error inside an adapter, with its file and line.
- **Subscribe to `status/*`** to see which sources are running.
- **`k.log(...)`** in an adapter prints to the same stderr.
- **Check the files load.** `kippsrv --check` loads the source files the way a
  start would, lists each source with its command and claim, and serves
  nothing. A refused file is logged with the reason, and the exit code is 1.
