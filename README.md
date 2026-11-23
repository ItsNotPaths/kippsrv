# kippsrv

Desktop state on one socket.

kippsrv runs the programs that know your desktop's state (the window manager,
bluez, NetworkManager, PipeWire, media players, the tray) and publishes what
they say on one unix socket, in [kipp](https://github.com/ItsNotPaths/kipp). A
program that subscribes at any moment gets the current values first, then each
change.

## Thanks

- **Andy Stanford-Clark and Arlen Nipper**, who designed [MQTT](https://mqtt.org).
  kipp takes MQTT's model and its names for things (topics, retained values,
  publishes, subscriptions, wills) and writes them as lines of text.
- **Tony Garnock-Jones**, whose PhD thesis built [Syndicate](https://syndicate-lang.org/).
  kippsrv borrows its rule that a fact lives only as long as whatever asserted
  it: when a media player or a D-Bus service goes away, its facts go with it.

## What it looks like

A kipp line is a verb, a topic, and `key=value` fields, separated by tabs:

```
retain	media/firefox/instance_1_719	status=Paused	title=Home / X	artist=	length=17
```

kippsrv is also a small broker. Other programs connect, subscribe to topics,
and publish facts of their own. A source that does not speak kipp gets an
adapter: a Lua file that turns its output into kipp lines, run in a VM inside
kippsrv. kippsrv itself is written in Odin.

## Install and run

You need the [Odin](https://odin-lang.org) compiler, git, and meson, ninja and
gperf (for basu, below).

```sh
./download-deps.sh       # once: checks the tools, builds basu into vendor/
./build.sh               # kippsrv and kippbus into build/
build/kippsrv --install  # both into ~/.local/bin, the shipped source files into ~/.local/share
kippsrv                  # stays in the foreground; start it from your session's autostart
```

In a second terminal, with `socat`:

```sh
(printf 'connect\tme\nsubscribe\t*\n'; cat) | socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/kippsrv.sock"
```

You get every current value, then each change as it happens. `kippsrv --uninstall`
removes every file of kippsrv. HOWTO.md section
3 explains what comes back.

**[HOWTO.md](HOWTO.md)** covers the rest: which sources ship and what they
need, reading from kippsrv, writing a source file and an adapter, taking
requests, connecting your own program, and D-Bus. The binary carries it:
`kippsrv howto <word>` prints the parts about a word, and `kippsrv --help`
lists the rest. **[DIAGNOSTICS.md](DIAGNOSTICS.md)**
explains every message with a code in brackets.

## What is here

| | |
| --- | --- |
| `src/kipp.odin` | the wire: parse, build, serve, subscribe, broadcast |
| `src/loop.odin` | `poll()`. The only place that blocks |
| `src/lua.odin` | the VM and the sandbox around it |
| `src/source.odin` | running sources and cutting their output into lines |
| `src/store.odin` | the last value of each topic, and `kippsrv.state`, a copy of them for scripts |
| `src/command.odin` | requests: a publish, to every source that takes it |
| `src/config.odin` | source files: found, loaded, claims checked |
| `src/main.odin` | load the source files, serve, run |
| `bus/` | kippbus, the one D-Bus program, run by kippsrv as a source |
| `sources.d/` | the shipped source files, in their installed layout |

## Design notes

### The store

The store keeps the last value of each topic. It is what lets a consumer join
at any moment: a subscriber gets those values first and never needs the
history.

It also drops repeats. `nmcli` reprints every connection whenever anything
changes, and a poll rereads the same battery percentage all day, but only a
line that changed reaches the socket. That spares every consumer, but the source
does the same work as it would without a store: a poll still pays a fork, an
exec, a read and a Lua call to learn that nothing moved. Prefer a source that streams changes
(`kippbus match`, a socket) to one that polls.

### Topics are identities

A topic names a thing, and the payload holds its value. Build a topic from
something that cannot change: a UUID, a MAC, a bus name, a device path. A title
or a percentage in the topic would make every value a separate entry, and the
store would keep all of them.

kippsrv checks no topic names. They are a deal between a publisher and its
subscribers, and an adapter may retain a topic nobody has heard of. A test
fails if that stops being true.

### The sandbox

An adapter gets lines and returns fields. It never holds a descriptor and never
writes a raw line, so it cannot reach the filesystem or the network, and cannot
forge a fact with an embedded tab. Three guards, each for a different failure:

| Guard | Stops |
| --- | --- |
| no `io`, `os`, `package`, `debug`, `coroutine`, `require`, `dofile`, `loadfile` or `load` | reaching a file, a socket, or another process |
| a count hook, about 2M instructions per call | a script that never returns |
| a capped allocator, 64 MB | a script that asks for everything |

The second does not cover the third: `string.rep("x", 1e9)` is one C call, and
a count hook only fires between VM instructions. Hitting either limit raises an
ordinary Lua error. kippsrv logs it, loses that call's output, and carries on.

### Lint

`tests/lint.sh` checks three rules by reading the source tree:

- The core names no topic kind (the first part of a topic) that a shipped
  adapter emits, so the core never learns what a domain is.
- `src/lua.odin` never imports posix, so a script can never be handed a
  descriptor.
- kippsrv registers at most 12 functions in Lua. Today it registers 7:
  `k.retain`, `k.publish`, `k.json`, `k.parse`, `k.log`, `print` and `source`.

It does not prove them. A determined author can route around a grep, and the
check makes sure they notice they are doing it.

### A quiet source is asked less often

A poll that finds nothing new for three runs in a row has its period doubled,
up to sixteen times the configured one or a minute, whichever is smaller.
Anything new resets it.

In one measurement, 30 sources polling one command every 2 seconds used 2.2%
of a core with a fixed period and 0.5% with backoff. The CPU matters less than
the wakeups: 15 process creations a second leave no idle window longer than
about 66 ms, so the CPU never reaches its deep sleep states. A status bar should
not keep a laptop awake.

### A consumer that stops reading

Each consumer has a 256 KB queue. kippsrv sends everything queued for a
consumer in one write and keeps whatever part the kernel did not take for the
next try, so a consumer that pauses loses nothing. A consumer whose queue fills
is disconnected. When it connects and subscribes again, it gets the current
values.

In one measurement, a consumer that never read was disconnected after 10,466
lines. At a busy desktop's rate that is about half a minute.

Throughput is not the risk. One line through each layer:

| Layer | Rate |
| --- | --- |
| `parse` (Odin) | 2.4M lines/s |
| build (Odin) | 980k lines/s |
| a simple adapter (Lua) | 406k lines/s |
| the Hyprland adapter (Lua) | 325k lines/s |

The Lua call is the ceiling, about three orders of magnitude above what a
desktop produces.

### D-Bus lives in kippbus

kippsrv never learns what D-Bus is. `kippbus` is a second binary that holds one
bus connection, and kippsrv runs it from an ordinary source file like any other
command: lines out on stdout, requests in on stdin. HOWTO.md shows how to use it.

kippbus uses sd-bus, because sd-bus can export an interface with
`sd_bus_add_object_vtable`, which the tray and notification daemons need. With
libdbus that is manual message dispatch. It links basu, which is sd-bus
without systemd, statically, so kippbus needs no D-Bus library at run time.
kippsrv links no bus at all.

`download-deps.sh` clones basu from git.sr.ht at a pinned commit and builds it
once. `bus/sdbus.odin` lists every symbol kippbus uses.

### The wire

kippsrv implements kipp itself rather than vendoring the C library from the
[kipp repo](https://github.com/ItsNotPaths/kipp). The protocol is the contract:
a reader written against that library talks to kippsrv with no change.

## Build

```sh
./download-deps.sh --force   # rebuild basu
./build.sh test              # lint, unit tests, then a socat round trip (needs socat; dbus and gdbus for the bus checks)
./build.sh --version v1.2.3  # stamp the build: kippsrv --version prints it
PREFIX=/usr DESTDIR=pkg ./build.sh install --version v1.2.3   # system-wide, for a package
```

CI builds in an Alpine container, with Odin `dev-2026-10` and Lua 5.4.2 built there,
statically against musl. A release is a prefix tree: `tar -C /usr/local -xzf kippsrv-*.tar.gz`.
Both binaries are static, so they run on any x86_64 Linux, glibc or musl.

Maintainers cut a release with `./build.sh --public --version vX.Y.Z`, which
starts the release workflow through the `gh` CLI.
