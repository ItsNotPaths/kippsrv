# kippsrv

The shell daemon. It subscribes to every foreign source on the machine —
window manager, bluez, NetworkManager, PipeWire, D-Bus — normalizes what they
say into one vocabulary, and publishes it as kipp on one socket.

Odin, with an embedded Lua VM. One Lua file for each foreign source.

It is not a broker. It never learns who reads it. A new consumer costs it
nothing, and a new source costs it one Lua file.

## State

Step 3 of 6. A foreign format enters through a source, a Lua adapter converts
it, and kipp comes out of the socket. There is no store yet, so a fact
produced before a consumer connects is lost.

| | |
| --- | --- |
| `src/kipp.odin` | the wire: parse, build, serve, dump, broadcast |
| `src/loop.odin` | `poll()`. The only place that blocks |
| `src/lua.odin` | the VM, the fence, and a four-call script surface |
| `src/source.odin` | foreign sources and their framing |
| `src/main.odin` | **scaffolding.** A hardcoded desktop so the socket can be tested |
| `lua/wm/example.lua` | a stand-in adapter, until `wm/hypr.lua` exists |

Next: the store, then D-Bus.

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

Nothing in the code enforces that agreement, so `make tenet-vocab` does. It is
a grep: `lua/<domain>/<impl>.lua` may emit only the kinds in
`vocab/<domain>.txt`. A new kind is an edit to that file, which is a deliberate
act. It has already caught drift — the first two window manager adapters
written here shared exactly one kind out of nine.

A domain with one implementation cannot drift, so its file is documentation. A
domain with several is where the check earns its keep. The whole desktop is
about 22 kinds, and none of them is designed ahead of the adapter that needs
it.

**These files are a lint, not a schema.** The daemon contains no vocabulary and
consults nothing at runtime. An adapter may emit a kind no one has heard of and
it reaches a consumer untouched. `make tenet-vocab` covers `lua/` and nothing
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
| `backlight` | 1 | brightnessctl |

**An event stream needs a seed.** socket2 reports what changed, not what is,
so an adapter that has seen no events knows nothing. `hyprctl monitors -j` is a
second source attached to the *same* adapter, so both share its state. One
window manager is one file, however many sources it takes to read it.

kippsrv holds no routes. It names sources, never consumers. A configuration
that wired a source to a bar would make a second bar an edit to kippsrv.

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

`src/main.odin` holds domain nouns today and `tenet-core` does not cover it
yet. That debt closes when the store lands and the hardcoded state goes.

## The fence

A script gets parsed lines and returns fields. It never holds a descriptor and
never joins a line, so it cannot stall the loop and cannot forge a fact with an
embedded tab. `io`, `os`, `package`, `debug`, `coroutine`, `require`, `dofile`,
`loadfile` and `load` do not exist inside it.

`make tenet` proves all three of those mechanically rather than trusting them.

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
