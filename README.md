# kippsrv

Desktop state on one socket.

kippsrv reads every scattered source on the machine, normalizes what they say
into one vocabulary, and publishes it as [kipp](https://github.com/ItsNotPaths/kipp). A window manager, bluez,
NetworkManager, PipeWire, the tray. One socket, one format, and a consumer that
connects at any moment gets the whole truth before the changes.

Odin with an embedded Lua VM. One Lua file for each foreign source.

It is not a broker. It never learns who reads it, so a new consumer costs it
nothing and a new source costs it one Lua file.

```sh
make
./kippsrv config.lua
socat -u UNIX-CONNECT:"$XDG_RUNTIME_DIR/kippsrv.sock" -
```

```
version    1  kippsrv  proto=1
mon        eDP-1  w=2256  h=1504  scale=1.5
focus      eDP-1
tag        eDP-1  2  state=focused,occupied
net        c8119aa9-f0e2  name=Smith  type=802-11-wireless  state=up
sink       alsa_output.pci-0000_01_00.1  state=suspended
sync       state
```

## What is here

| | |
| --- | --- |
| `src/kipp.odin` | the wire: parse, build, serve, dump, broadcast |
| `src/loop.odin` | `poll()`. The only place that blocks |
| `src/lua.odin` | the VM, the fence, a seven-function script surface |
| `src/source.odin` | foreign sources and their framing |
| `src/store.odin` | current truth: dedup, the dump, the projection |
| `src/dbus.odin` | D-Bus signals and calls, through sd-bus |
| `src/command.odin` | the outbound seam: a command, offered to each source |
| `src/watcher.odin` | owns `org.kde.StatusNotifierWatcher` |
| `src/config.odin` | the configuration file, which is Lua |
| `src/main.odin` | load the config, serve, run |

Thirteen adapters across eight domains in `lua/`. A consumer reads the whole
desktop off one socket, and drives what only this process can reach.

## Configuration is Lua

`config.lua` returns a table. It runs in the same fenced VM as an adapter, so
it cannot read a file or open a socket either, and no key means "run this".
`$VAR` and `~` are expanded by kippsrv, so nothing in Lua reaches a variable it
was not handed.

```lua
return {
	socket = "$XDG_RUNTIME_DIR/kippsrv.sock",
	state  = "$XDG_RUNTIME_DIR/kippsrv.state",
	sources = {
		{ name = "tray", watcher = true, adapter = "lua/tray/snw.lua" },
		{ name = "notify", notify = true, adapter = "lua/notify/fdo.lua" },

		{ name = "wm-seed", adapter = "lua/wm/hypr.lua",
		  exec = {"hyprctl", "monitors", "-j"} },
		{ name = "wm", adapter = "lua/wm/hypr.lua",
		  sock = "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" },

		{ name = "net", adapter = "lua/net/nm.lua", every = 5000,
		  exec = {"nmcli","-t","-f","UUID,NAME,TYPE,DEVICE","connection","show"} },
	},
}
```

An adapter file is loaded once however many sources name it. That is what lets
the seed and the stream above share one state: `hyprctl monitors -j` sets the
focused monitor, and socket2 uses it.

A source with `every` runs again on that period. A command that ends becomes a
poll, so there is no separate polling concept.

## Sources and framing

| Kind | Gives |
| --- | --- |
| `exec` | spawn a command, read its output |
| `sock` | connect to a unix socket |
| `dbus` | subscribe to a signal, or own a name |
| `timer` | fire on a period and call `tick` |

A source owns the descriptor **and the framing**, so an adapter always gets a
whole unit. Nothing in Lua reassembles a torn line or a torn frame.

| Framing | Splits on |
| --- | --- |
| `Lines` | a newline. Nearly every text tool |
| `Prefix{header, at, width, le}` | a length field in a fixed header. i3 and sway are `{14, 6, 4, true}` |
| `Raw` | nothing. Whatever arrived |

The end of a descriptor ends a batch and calls `flush`. A last line with no
trailing newline is still a line.

## Polls back off when they learn nothing

After three quiet cycles a source's period doubles, up to sixteen times the
configured one or a minute, whichever is smaller. Anything new resets it.

Measured here, 30 sources polling one command every 2 seconds:

| | CPU |
| --- | --- |
| fixed period | 2.2% of a core, forever |
| with backoff, settled | 0.5% |

The CPU is not really the point. 15 process creations a second leaves no idle
window longer than about 66 ms, so deep C-states never engage. A status bar is
the last thing that should keep a laptop awake.

`steady = true` turns it off. Use it for anything a person drives: press the
volume key and a backed-off source can take 32 seconds to notice. `audio` and
`backlight` are both marked steady in the shipped config, and both are polls
that should not exist. Volume is a PipeWire subscription, and
`/sys/class/backlight/*/brightness` is watchable with inotify.

## The store

A source repeats itself. `nmcli` reprints every connection whenever anything
changes, and a poll rereads the same battery percentage all day. The store
keeps the last value for each fact and passes on only what moved.

A fact is identified by its kind and its positional subject, so
`tag eDP-1 2 state=occupied` replaces `tag eDP-1 2 state=focused` rather than
sitting beside it.

Only the adapter knows whether something has a current value:

| Call | Means |
| --- | --- |
| `k.emit` | a fact with a current value. Stored, deduplicated, in the dump |
| `k.event` | something happened. Passed on, never stored |
| `k.drop` | this fact no longer exists |

A source that dies does not lose its facts. They are marked `stale`, so a bar
can grey out a headphone that still exists rather than claim it is gone.

**The store is a correctness feature, not a performance one.** A repeat costs
nothing downstream: the socket and every consumer are spared. Upstream it costs
exactly as much as ever. A poll still pays a fork, an exec, a read and a Lua
call to find out that nothing moved. Prefer `dbus` or `sock` to `every`
wherever a source offers one.

## Subjects are identities

A subject identifies a fact. A value goes in an attribute.

Use something that cannot hold `=`: a UUID, a MAC, a bus name, a device path.
The framing rule reads the first field holding `=` as the start of the
attributes, so a subject holding one leaves the fact with no subject at all,
keyed on its bare kind, colliding with every other fact of that kind. kippsrv
refuses such a fact and says which file and field caused it.

```lua
k.emit("net", "home=wifi", "type=wifi")            -- refused
k.emit("net", uuid, "name=home=wifi", "type=wifi") -- fine
```

The name is legal in an attribute, because only the first `=` separates a key
from its value. And the same rule catches a subtler mistake: a title or a
percentage in the subject makes every value a separate fact, and the store
keeps all of them.

## One vocabulary

A window manager adapter converts a foreign format into the kinds in
`vocab/wm.txt`. Every adapter emits the same ones, so a bar carries one parser
and never a file per window manager. Swapping Hyprland for dwl is one adapter
file and one line of config, and no consumer notices.

`make lint` makes drift visible: `lua/<domain>/<impl>.lua` may emit only the
kinds in `vocab/<domain>.txt`. It has already caught some. The first two window
manager adapters written here shared one kind out of nine.

| Domain | Kinds | Implementations |
| --- | --- | --- |
| `wm` | 8 | hypr, dwl, i3/sway |
| `net` | 1 | nm |
| `audio` | 1 | pw |
| `power` | 1 | upower |
| `media` | 1 | mpris |
| `backlight` | 1 | brightnessctl |
| `tray` | 1 | snw |
| `notify` | 1 | fdo |
| `bt` | 2 | bluez |

**These files are a lint, not a schema.** The daemon holds no vocabulary and
consults nothing at run time. An adapter may emit a kind nobody has heard of
and it reaches a consumer untouched, and there is a test that fails if that
stops being true. `make lint` covers `lua/` and nothing else, so an adapter you
write in your own config directory is never seen by it.

A new domain is a directory and a file. `vocab.sh` walks `lua/*/`, so nothing
holds a list of domains.

What you give up by inventing a kind is that our bar will not draw it. Emitting
`tag` is a benefit taken, not a permission asked for. That is the inverse of
the Wayland problem, where a new noun costs a protocol, a compositor
implementation and agreement upstream, so applications route around it instead.
Here a new noun costs one line, and matching costs a page.

**An event stream needs a seed.** socket2 reports what changed, not what is, so
an adapter that has seen no events knows nothing. `hyprctl monitors -j` is a
second source on the same adapter. One window manager is one file, however many
sources it takes to read it.

kippsrv holds no routes. It names sources, never consumers.

## Commands go back out

A consumer sends an uppercase line on the same connection. Each source is
offered it in configuration order and the first adapter that answers owns it.

| An adapter returns | The core does |
| --- | --- |
| nothing | asks the next source |
| a string | writes those bytes to the source's channel |
| a table | makes that method call on the source's own bus |
| `nil, code, msg` | sends back that `error` line |

A source that names `cmd` has that path opened for each write. One without it
answers on the socket it already has. There is no third way out, and an adapter
sees neither descriptor. `lua/wm/hedl.lua` is the first shape, `lua/tray/snw.lua`
the second, `src/command.odin` the whole of it.

```lua
{ name = "wm", adapter = "lua/wm/hedl.lua",
  sock = "$XDG_RUNTIME_DIR/hedl/kipp", cmd = "$XDG_RUNTIME_DIR/hedl/cmd" },
```

**The path is narrow on purpose.** Most of what a consumer wants is to run a
command, and anything can run a command. What is left is where kippsrv holds
the only descriptor that reaches the thing. The tray is the case with no other
way: an icon is activated on the connection it registered on, and that
connection is this process's.

## The fence

A script gets parsed lines and returns fields. It never holds a descriptor and
never joins a line, so it cannot reach the filesystem or the network and cannot
forge a fact with an embedded tab. `io`, `os`, `package`, `debug`, `coroutine`,
`require`, `dofile`, `loadfile` and `load` do not exist inside it.

That is one guarantee, not three. Dropping `io` says nothing about
`while true do end`, and nothing about `string.rep("x", 1e9)`.

| Guard | Stops |
| --- | --- |
| the sandbox | reaching a file, a socket, or another process |
| a count hook, ~2M instructions per call | a script that never returns |
| a capped allocator, 64 MB | a script that asks for everything |

The second does not cover the third. `string.rep` is one C call and a count
hook only fires between VM instructions. Refusing an allocation raises an
ordinary Lua memory error, which `pcall` catches, so the loop carries on either
way.

`make lint` makes drift in the sandbox, the descriptor rule and the surface
size visible in a diff. It does not prove them. A determined author routes
around a grep, and what the check buys is that they have to notice they are
doing it. The two budgets have their own tests.

## D-Bus

```lua
{ name = "media", adapter = "lua/media/mpris.lua",
  dbus = {"type='signal',interface='org.freedesktop.DBus.Properties'"} },
```

Match rules are the same strings `busctl` and `dbus-monitor` take. A signal
reaches the adapter as the JSON `busctl` prints, so one file works whether a
fact was polled or pushed. `lua/media/mpris.lua` handles both, and the only
difference is which branch of its `feed` runs.

Getting that right meant collapsing variants the way busctl does. A value of
type `v` reaches Lua as whatever it holds, so an adapter never learns something
arrived wrapped.

### The watcher

`src/watcher.odin` owns `org.kde.StatusNotifierWatcher`. That is the one thing
`busctl` cannot do for us, and a tray application looks for that name once at
its own startup, so if nobody owns it no icon ever registers.

It exports two methods, three properties and three signals, tracks what is
registered, and drops an entry when its application leaves the bus. Its state
is one table, so there is one watcher, and a second `watcher = true` is refused
with a message. `bus_name` owns a different name, for testing beside a live
one.

**The kind is named in Lua, not here.** Registrations reach `lua/tray/snw.lua`
as a JSON line, the same shape a D-Bus source gets, and it decides they are
`tray` facts. The core knows "items" and "dropped", which are facts about a
D-Bus interface and no noun of the desktop, so `lint-core` covers this file
like every other.

### sd-bus, not libdbus

libdbus is everywhere and would make exporting an interface manual message
dispatch. sd-bus has `sd_bus_add_object_vtable`.

sd-bus has two implementations, and basu is the same API without systemd:

```sh
make            # libsystemd, for a dev machine that has it
make static     # basu, fetched at a pinned commit and linked in
```

`make static` leaves a binary needing no D-Bus library at run time, and it is
the one to package. It is also the only build with no second path waiting to
fail somewhere else: what you test is what you ship.

basu is pinned in the Makefile, not copied into this repo. 34k lines of someone
else's C does not belong in the tree, and a pinned commit gives the same
reproducibility. Building it needs meson, ninja and gperf.

The dependency is 15 symbols for reading, listed at the top of `src/dbus.odin`,
two for calling out and ten for owning a name and answering on it. All 27 are
in basu. Nothing else in kippsrv touches the
bus, and a source polling `busctl` needs none of it. That is how
`lua/media/mpris.lua` worked before `dbus.odin` existed.

The vtable struct is the one place they disagree. libsystemd is 56 bytes and
carries parameter names and a format reference. basu is 48 and does not.
`sd_bus_add_object_vtable` rejects a mismatch at run time rather than compile
time, so the layout follows the same `when` switch as the library.

## What the adapters absorb

Eight real formats, captured from live programs and kept in `test/fmt/`. Each
converts through one Lua file and nothing downstream learns it.

| Shape | Source | Adapter |
| --- | --- | --- |
| `event>>data`, commas inside values | Hyprland socket2 | `lua/wm/hypr.lua` |
| space separated, title last | dwl `printstatus` | `lua/wm/dwl.lua` |
| length-prefixed binary | i3 and sway | `lua/wm/i3.lua` |
| colon separated, backslash escapes | `nmcli -t` | `lua/net/nm.lua` |
| tab separated | `pactl list short` | `lua/audio/pw.lua` |
| comma separated | `brightnessctl -m` | `lua/backlight/brightnessctl.lua` |
| indented, one record over many lines | `upower -i` | `lua/power/upower.lua` |
| JSON | `busctl --json=short` | `lua/media/mpris.lua` |

Two of those forced the API to grow, and the tests found both before the design
did. A record spanning lines has no terminator on the last one, so `feed` alone
produced nothing and an adapter now gets told when a batch ends. And Lua has no
JSON decoder, so writing one per adapter in the wrong language lost to one call
backed by `core:encoding/json`.

An adapter **can** hold state. The table it returns lives for the life of the
source, so an upvalue survives between feeds. `upower.lua` needs that.

Binary is not out of reach either. Lua strings are 8-bit clean and
`string.pack` and `string.unpack` are in the `string` library, so an adapter
reads a length-prefixed frame itself and Odin never learns the magic string.
What belongs to the source is framing, not parsing.

## Measured

One line through each layer:

| Layer | Rate |
| --- | --- |
| `parse` (Odin) | 2.4M lines/s |
| build (Odin) | 980k lines/s |
| a simple adapter (Lua) | 406k lines/s |
| the Hyprland adapter (Lua) | 325k lines/s |

The Lua call is the ceiling, about three orders of magnitude above what a
desktop produces. Throughput is not the risk.

**The risk is a consumer that stops reading.** A unix socket charges per
message, not per byte. One `send` of one line costs about 766 bytes of kernel
buffer, so a 208 KB buffer holds 278 lines carrying 9.7 KB of payload, and a
consumer that stalled used to be dropped after 278 of them.

Three changes fixed that, all in `srv_flush`. A pass goes out in one send
rather than one send per line, which fits ten times as many lines in the same
kernel buffer. Each consumer has a 256 KB queue in front of that. And a write
that only partly lands keeps its remainder for the next pass, so a momentary
stall is no longer fatal.

A consumer that never reads now takes **10,466 lines** to drop. At a busy
desktop rate that is half a minute of not reading, and a bar stalled that long
is already dead.

## When something goes wrong

Every message with a code in brackets is explained in
[DIAGNOSTICS.md](DIAGNOSTICS.md), and each says who can fix it. A message
naming an adapter file is a bug in that adapter, not in your configuration, and
that file is the one to report against.

Anything starting `config:` is yours to correct and names the key it expected.

## The wire

kippsrv implements kipp itself rather than vendoring it. The protocol is the
contract, so two implementations that drift still interoperate, which an ABI
does not. Readers written against the C implementation in the [kipp repo](https://github.com/ItsNotPaths/kipp) talk to
this one with no change.

## Build

```sh
make          # kippsrv
make static   # with basu linked in
make check    # lint, unit tests, then a socat round trip
make lint     # the four architecture checks alone
```
