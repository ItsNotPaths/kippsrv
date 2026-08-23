# kippsrv

The shell daemon. It subscribes to every foreign source on the machine —
window manager, bluez, NetworkManager, PipeWire, D-Bus — normalizes what they
say into one vocabulary, and publishes it as kipp on one socket.

Odin, with an embedded Lua VM. One Lua file for each foreign source.

It is not a broker. It never learns who reads it. A new consumer costs it
nothing, and a new source costs it one Lua file.

## State

Step 5 of 6. `kippsrv config.lua` reads a live machine through as many sources
as you name, keeps what is current, and publishes it as kipp on one socket.

| | |
| --- | --- |
| `src/kipp.odin` | the wire: parse, build, serve, dump, broadcast |
| `src/loop.odin` | `poll()`. The only place that blocks |
| `src/lua.odin` | the VM, the fence, and a four-call script surface |
| `src/source.odin` | foreign sources and their framing |
| `src/store.odin` | current truth: dedup, the dump, the projection |
| `src/dbus.odin` | D-Bus signals, through sd-bus |
| `src/config.odin` | the configuration file, which is Lua |
| `src/main.odin` | load the config, serve, run |
| `lua/wm/example.lua` | a stand-in adapter, until `wm/hypr.lua` exists |

Next: owning a D-Bus name, and the outbound command path.

## D-Bus

```lua
{ name = "media", adapter = "lua/media/mpris.lua",
  dbus = {"type='signal',interface='org.freedesktop.DBus.Properties'"} },
```

The match rules are the same strings `busctl` and `dbus-monitor` take. A signal
arrives at the adapter as **the JSON busctl prints**, so one adapter file works
whether a fact was polled or pushed. `lua/media/mpris.lua` handles both, and
the only difference is which branch of its `feed` runs.

Getting that right needed the writer to collapse a variant the way busctl
does. A D-Bus value of type `v` reaches Lua as whatever it holds, so an adapter
never learns that something arrived wrapped.

**sd-bus, not libdbus.** libdbus is available everywhere and would make
exporting an interface manual message dispatch, which is the next thing to
build. sd-bus has `sd_bus_add_object_vtable` instead.

sd-bus has two implementations. basu is the same API without systemd, and it
is the one to package:

```sh
make            # libsystemd, for a dev machine that has it
make static     # basu, fetched at a pinned commit and linked in
```

`make static` leaves a binary that needs no D-Bus library at run time. That is
also the only build with no second path waiting to fail somewhere else: what
you test is what you ship.

basu is pinned in the Makefile, not copied into this repo. 34k lines of
someone else's C does not belong in the tree, and a pinned commit gives the
same reproducibility without them. Building it needs meson, ninja and gperf.

The dependency is 15 symbols, listed at the top of `src/dbus.odin`. All 15 are
in basu, along with the five that owning a name will need. Nothing else in
kippsrv touches the bus, and a source that polls `busctl` instead needs none of
it — which is how `lua/media/mpris.lua` worked before this file existed.

## The watcher

`src/watcher.odin` owns `org.kde.StatusNotifierWatcher` and answers on it. That
is the one thing `busctl` cannot do for us. A tray application looks for that
name once, at its own startup, so if nobody owns it no icon ever registers.

```lua
{ name = "tray", watcher = true, adapter = "lua/tray/snw.lua" },
```

Its state is one table, so there is one watcher. `bus_name` owns a different
name, for testing beside a live one, and a second `watcher = true` is refused
with a message.

It exports two methods, three properties and three signals, tracks what is
registered, and drops an entry when its application leaves the bus.

**The kind is named in Lua, not here.** The registrations reach
`lua/tray/snw.lua` as a JSON line, the same shape a D-Bus source gets, and it
decides they are `tray` facts. The core knows "items" and "dropped", which are
facts about a D-Bus interface, and no noun of the desktop — so `lint-core`
covers this file like every other.

**The vtable struct differs between the two sd-bus implementations.**
libsystemd is 56 bytes and carries parameter names and a format reference.
basu is 48 and does not. `sd_bus_add_object_vtable` rejects a mismatch at run
time rather than compile time, so the layout follows the same `when` switch as
the library.

## Configuration is Lua

`config.lua` returns a table. It runs in the same fenced VM as an adapter, so
it cannot read a file or open a socket either, and there is no key that means
"run this". `$VAR` and `~` are expanded by kippsrv, so nothing in Lua reaches a
variable it was not handed.

```lua
return {
	socket = "$XDG_RUNTIME_DIR/kippsrv.sock",
	state  = "$XDG_RUNTIME_DIR/kippsrv.state",
	sources = {
		{ name = "wm-seed", adapter = "lua/wm/hypr.lua",
		  exec = {"hyprctl", "monitors", "-j"} },
		{ name = "wm", adapter = "lua/wm/hypr.lua",
		  sock = "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" },
		{ name = "net", adapter = "lua/net/nm.lua", every = 5000,
		  exec = {"nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show"} },
	},
}
```

An adapter file is loaded once however many sources name it, so the seed and
the stream above share one state. A source with `every` runs again on that
period, which is how a command that ends becomes a poll.

**A poll that learns nothing is asked for less often.** After three quiet
cycles the period doubles, up to sixteen times the configured one or a minute,
whichever is smaller. Anything new puts it straight back. `steady = true` turns
that off for a source that must be sampled at a fixed rate.

Measured on this machine, 30 sources polling one command every 2 seconds:

| | CPU |
| --- | --- |
| fixed period | 2.2% of a core, forever |
| with backoff, settled | 0.5% |

The saving is not the CPU so much as the wakeups. 15 process creations a
second leaves no idle window longer than about 66 ms, and deep C-states never
engage. A status bar is the last thing that should keep a laptop awake.

## The store

A source repeats itself. `nmcli` reprints every connection whenever anything
changes, and a poll rereads the same battery percentage all day. The store
keeps the last value for each fact and passes on only what moved.

A fact is identified by its kind and its positional subject, so
`tag eDP-1 2 state=occupied` replaces `tag eDP-1 2 state=focused` rather than
sitting beside it.

Only the adapter knows whether something has a current value, so only the
adapter says:

| Call | Means |
| --- | --- |
| `k.emit` | a fact with a current value. Stored, deduplicated, in the dump |
| `k.event` | something happened. Passed on, never stored |
| `k.drop` | this fact no longer exists |

A consumer connecting at any moment reads the full current state and then the
changes, so it never has to have heard the history.

**The store is a correctness feature, not a performance one.** A repeat costs
nothing *downstream*: the socket and every consumer are spared. It costs the
same as ever *upstream*. A poll still pays a fork, an exec, a read, a Lua call
and two parses to find out that nothing moved, and no amount of deduplication
touches that. Prefer `dbus` or `sock` to `every` wherever the source offers
one.

The projection is written from the same table, once a pass, and only when
something moved.

## Measured

On this machine, one line through each layer:

| Layer | Rate |
| --- | --- |
| `parse` (Odin) | 2.4M lines/s |
| build (Odin) | 980k lines/s |
| a simple adapter (Lua) | 406k lines/s |
| the Hyprland adapter (Lua) | 325k lines/s |

The Lua call is the ceiling and it sits about three orders of magnitude above
what a desktop produces. Throughput is not the risk.

**The risk is a consumer that stops reading.** A unix socket charges per
message, not per byte: one `send` of one line costs about 766 bytes of kernel
buffer, so a 208 KB buffer holds 278 lines carrying 9.7 KB of payload. A
consumer that stalled was dropped after 278 lines.

Three changes, all in `srv_flush`:

- A pass is written in **one** send, not one send per line. Ten times as many
  lines fit the same kernel buffer.
- Each consumer has a 256 KB queue in front of that.
- A write that only partly lands keeps its remainder for the next pass. A
  consumer that stalls for a moment is no longer dropped for it.

A consumer that never reads now takes **10,466 lines** to drop, against 278.
At a busy desktop rate of a few hundred lines a second that is half a minute of
a consumer not reading, and a bar stalled that long is already dead.

What none of this fixes is a source repeating the same fact. That is the
store's job, and it is next.

## One vocabulary, or the hop bought nothing

A window manager adapter converts a foreign format into the kinds listed in
`test/vocab-wm.txt`. Every adapter emits the same ones, so the bar carries one
parser and never a file per window manager. Swapping Hyprland for dwl is one
adapter file and one line of configuration, and no consumer notices.

Nothing in the code enforces that agreement, so `make lint` makes it
visible. It is a grep: `lua/<domain>/<impl>.lua` may emit only the kinds in
`vocab/<domain>.txt`. A kind built from a variable is invisible to it. A new kind is an edit to that file, which is a deliberate
act. It has already caught drift — the first two window manager adapters
written here shared exactly one kind out of nine.

A domain with one implementation cannot drift, so its file is documentation. A
domain with several is where the check earns its keep. The whole desktop is
about 22 kinds, and none of them is designed ahead of the adapter that needs
it.

**These files are a lint, not a schema.** The daemon contains no vocabulary and
consults nothing at runtime. An adapter may emit a kind no one has heard of and
it reaches a consumer untouched. `make lint` covers `lua/` and nothing
else: an adapter a user writes lives in their own configuration directory, is
never seen by it, and may emit whatever it likes. There is a test that fails if
that ever stops being true.

A new domain is a directory and a file. `vocab.sh` walks `lua/*/`, so nothing
holds a list of domains and adding one changes no code.

What a user gives up by inventing a kind is only that our bar will not draw it.
Emitting `tag` is a benefit taken, not a permission asked for — which is the
inverse of the Wayland problem. There a new noun costs a protocol, a compositor
implementation and agreement upstream, so applications route around it. Here a
new noun costs one line and no one's consent, and what costs anything is
matching, which is a page.

| Domain | Kinds | Implementations |
| --- | --- | --- |
| `wm` | 8 | hypr, dwl, i3 and sway |
| `net` | 1 | nm |
| `audio` | 1 | pw |
| `power` | 1 | upower |
| `media` | 1 | mpris |
| `backlight` | 1 | brightnessctl |

**An event stream needs a seed.** socket2 reports what changed, not what is,
so an adapter that has seen no events knows nothing. `hyprctl monitors -j` is a
second source attached to the *same* adapter, so both share its state. One
window manager is one file, however many sources it takes to read it.

kippsrv holds no routes. It names sources, never consumers. A configuration
that wired a source to a bar would make a second bar an edit to kippsrv.

## When something goes wrong

Every message carrying a code in brackets is explained in
[DIAGNOSTICS.md](DIAGNOSTICS.md), and each one says who can fix it. A message
that names an adapter file is a bug in that adapter, not in your
configuration — the file it names is the one to report against.

Anything starting `config:` is yours to correct, and names the key it expected.

## Sources

| Kind | Gives |
| --- | --- |
| `exec` | spawn a command, read its output |
| `sock` | connect to a unix socket |
| `timer` | fire on a period, and call `tick` |
| `dbus` | subscribe to a signal (`dbus.odin`, not written) |

A source owns the descriptor **and the framing**, so an adapter always gets a
whole unit and never reassembles a torn one.

| Framing | Splits on |
| --- | --- |
| `Lines` | a newline. Nearly every text tool |
| `Prefix{header, at, width, le}` | a length field inside a fixed header. i3 and sway are `{14, 6, 4, true}` |
| `Raw` | nothing. Whatever arrived |

The end of a descriptor is the end of a batch, so it calls `flush`. A last line
with no trailing newline is still delivered as a line.

```sh
./kippsrv /tmp/k.sock exec lua/wm/hypr.lua sh -c 'cat test/fmt/hypr-socket2.txt'
socat -u UNIX-CONNECT:/tmp/k.sock -
```

## What the adapters absorb

Seven real formats, captured from live programs on a real machine and kept in
`test/fmt/`. Each one converts through one Lua file and nothing downstream
learns it.

| Shape | Source | Adapter |
| --- | --- | --- |
| `event>>data`, commas inside values | Hyprland socket2 | `lua/wm/hypr.lua` |
| space separated, title last | dwl `printstatus` | `lua/wm/dwl.lua` |
| colon separated, backslash escapes | `nmcli -t` | `lua/src/nm.lua` |
| tab separated | `pactl list short` | `lua/src/pw.lua` |
| comma separated | `brightnessctl -m` | `lua/src/backlight.lua` |
| indented, one record over many lines | `upower -i` | `lua/src/upower.lua` |
| JSON | `hyprctl monitors -j` | `lua/src/hyprmon.lua` |

Two of those forced the API to grow, and the test found both before the design
did:

- **`flush`.** A record spanning lines has no terminator on the last one, so
  `feed` alone produced nothing. An adapter now gets told when a batch ends.
- **`k.json`.** Lua has no decoder. Writing one per adapter in the wrong
  language is worse than one call backed by `core:encoding/json`.

An adapter **can** hold state. The table it returns lives for the life of the
source, so an upvalue survives between feeds. `upower.lua` needs that.

Binary is not out of reach. Lua strings are 8-bit clean and `string.pack` and
`string.unpack` are in the `string` library, so an adapter reads a
length-prefixed frame itself. `lua/src/framed.lua` does exactly that with an
i3-shaped frame, and Odin never learns the magic string.

What belongs to the source is **framing**, not parsing. It already buffers
bytes and splits on a newline for line formats. A second mode splits on a
length prefix instead, so the adapter always gets a whole frame and never a
partial one. That keeps the script surface at four calls and gives the core one
more transport noun rather than a foreign protocol.

Two things had to change to allow it. `feed` now pushes with `pushlstring`, so
a frame holding a NUL byte is not cut at the first one. And a source can hand
over a chunk instead of a line.

`tenet-core` now covers every Odin file. No domain noun is left in the core.

## The fence

A script gets parsed lines and returns fields. It never holds a descriptor and
never joins a line, so it cannot reach the filesystem or the network and cannot
forge a fact with an embedded tab. `io`, `os`, `package`, `debug`, `coroutine`,
`require`, `dofile`, `loadfile` and `load` do not exist inside it.

**The sandbox does not stop a script from spending too much.** Dropping `io`
says nothing about `while true do end`, and nothing about
`string.rep("x", 1e9)`. Those are three different guarantees and the first does
not imply either of the others.

| Guard | Stops |
| --- | --- |
| the sandbox | reaching a file, a socket, or another process |
| a count hook, about 2M instructions per call | a script that never returns |
| a capped allocator, 64 MB | a script that asks for everything |

The second does not cover the third: `string.rep` is one C call, and a count
hook only fires between VM instructions. Refusing an allocation makes Lua
raise an ordinary memory error, which `pcall` catches like any other, so the
loop carries on either way.

`make lint` makes drift in the sandbox, the descriptor rule and the surface
size visible in a diff. It does not prove them: a determined author routes
around a grep. What it buys is that they have to notice they are doing it,
which moves the trust from memory to review. The two budgets have their own
tests.

## Build

```sh
make          # kippsrv
make check    # tenets, unit tests, then a socat round trip
./kippsrv /tmp/x.sock
socat - UNIX-CONNECT:/tmp/x.sock
```

## The wire

Its own implementation, not a vendored one. The protocol is the contract, so
two implementations that drift still interoperate. Readers written against the
C implementation talk to this one with no change.
