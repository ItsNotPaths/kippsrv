<!-- (swiss :tags (wire broker sources lua bus lint) :sev (blocker gap polish)) -->

# kippsrv v2

kippsrv becomes a small broker for kipp v2 plus a Lua VM for adapters. The D-Bus work moves to a
second binary, kippbus. Edited in place. Decided 2026-11-21; the talk is in
`~/Projects/talk.md`, section 11.

**Waits on kipp.** `wire-v2` and everything after it follow `~/Projects/kipp/ws.md`, hole
`spec-v2`. swiss does not link holes across repos, so this need lives here in prose.

## Decided

- **What kippsrv is:** run sources, read their lines, keep what is retained, pass on what is not,
  serve subscribers. It never learns what D-Bus is.
- **The wire is kipp v2:** MQTT's meaning as text, MQTT's words, topics, `*` wildcards through
  `fnmatch(3)`, no binary, version 2. See kipp's ws.md.
- **Programs connect to kippsrv's socket directly.** The first line is `connect <name>`. A
  program may retain only what the source file of that name claims. Anyone may send a plain
  publish (requests, events).
- **No config file.** Sources live in files under `sources.d/`. kippsrv reads
  `/usr/share/kippsrv/sources.d/`, then `~/.config/kippsrv/sources.d/`, and a user file replaces
  the system file of the same name. The folder is the ledger: no request API, no popup. Apps and
  packages drop a file in. To disable a system file, copy it over and comment its sources out.
- **A source file declares its sources with Lua calls** (option A in the talk). Uncommented is on,
  commented out is off:

  ```lua
  source { name = "net", exec = "nmcli -t -f UUID,NAME,TYPE,DEVICE connection show", every = 5000, retains = "net/*" }
  source { name = "oket2", retains = "oket/*" }   -- a claim only: oket2 connects and publishes itself
  --source { name = "net-watch", exec = "nmcli monitor", retains = "net/*" }

  function feed(line) ... end
  ```

- **Claims.** `retains` names the topics a file owns. A second file claiming the same topics is
  refused at load, and the message names both files. A retain outside a source's claim is
  refused.
- **A file with no `feed` passes kipp lines straight through.** `lua/kipp.lua` goes.
- **`exec` runs through `sh -c`.** stdout is the way in and stdin is the way back. `cmd=` goes.
- **Lines only.** The `Prefix` and `Raw` framings go, and `lua/wm/i3.lua` with them.
- **Requests are subscriptions.** An adapter subscribes to a topic like `tag/request`. The
  "offer the command to each source in config order" path goes.
- **kippbus** is a second Odin binary in this repo with three subcommands: `match` (its own bus
  connection, AddMatch, method calls read from stdin), `tray` (owns
  `org.kde.StatusNotifierWatcher`) and `notify` (owns `org.freedesktop.Notifications`). kippsrv
  starts each one from an ordinary source file, so it needs no dinit file. kippsrv then drops
  sd-bus, basu and `make static`.
- **The line `kippbus match` reads on stdin** is
  `call <destination> <path> <interface> <member> <signature> <argument>...`, tab-separated like
  kipp. A bus adapter's `request` returns it as a string. Decided 2026-11-22.
- **A file with no `request` is sent the request line as it is**, the way a file with no `feed`
  passes kipp through. `kippbus tray` and `kippbus notify` read kipp requests on stdin this way.
  Decided 2026-11-22.
- **A notification displayer just subscribes to `notif/*`.** `kippbus notify` exists only because
  foreign apps send through D-Bus.
- **A bridge to real MQTT** is a source file over `mosquitto_sub` and `mosquitto_pub`.
- **No `stale`.** kippsrv retains `status/<source> state=online` or `state=offline` for each
  source it runs, as kipp's spec does for clients. The payload carries the source's claim,
  `retains=<pattern>`, so a reader matches its own topics against it and needs no mapping.
  Decided 2026-11-21. kipp may still gain `stale` if it proves better on its own merits.
- **Source files are flat.** The repo holds them in `sources.d/`, the installed layout, named
  `<domain>-<tool>.lua`. Shipped files are on, except files that claim a contested family:
  the window managers ship with their sources commented out. Decided 2026-11-21.
- **`retains` is one pattern or a list.** Two files conflict when a pattern of one fnmatches a
  pattern of the other as text. Sources in one file may share a claim. A source name is unique
  across all files; a second file using a taken name is refused like a claim. Decided
  2026-11-21.
- **XDG throughout.** The socket and state live in `$XDG_RUNTIME_DIR`. Source files come from
  `$XDG_CONFIG_HOME/kippsrv/sources.d` (default `~/.config`), then each of `$XDG_DATA_DIRS`
  (default `/usr/local/share:/usr/share`); the first folder holding a name wins. Tests point
  these at a temporary folder. Decided 2026-11-21.
- **An adapter names the requests it takes with `takes`** on its `source{}` line, beside
  `retains`. A publish reaches every source whose `takes` matches, as MQTT delivers to every
  subscriber. Decided 2026-11-21.

## Open

- **The payload rule** (only `key=value`, or positional too) is open in kipp's ws.md.
- **`lint-core` and `lint-api`** derive from `vocab/` and from the Lua surface, which both change.

No code site, so these stay in prose: `README.md` and `DIAGNOSTICS.md` (E-subject, E-cmdemit and
the `config:` messages change; E-claim is new).

## Workstream A: wire and broker

`wire-v2` first, then the store and subscriptions. `connect` waits on claims from workstream B.

<!-- (skeleton :tags (wire broker)) -->

_No holes match this query._

<!-- /skeleton -->

## Workstream B: source files

`source{}`, then `sources.d/`, then claims. `exec-sh`, `exec-stdin` and `lines-only` stand alone.

<!-- (skeleton :tags sources) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **source-state** · sources · ready
  - [src/source.odin:22](src/source.odin#L22) · polish · the life of a source is spread over done, dead, fails, pid, fd and input; one state enum.

<!-- /skeleton -->

## Workstream C: the Lua surface and the adapters

The surface, then the passthrough, then each adapter moves its source lines out of config.lua and
emits topics.

<!-- (skeleton :tags lua) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **media-seed** · lua · ready
  - [sources.d/media-mpris.lua:62](sources.d/media-mpris.lua#L62) · gap · no source polls GetAll, so a player already playing shows nothing until it changes.

<!-- /skeleton -->

## Workstream D: kippbus

Move `dbus.odin`, `watcher.odin` and `notify.odin` out. `drop-sdbus` is the goal.

<!-- (skeleton :goal drop-sdbus) -->

_Built: **drop-sdbus**._

_No holes match this query._

<!-- /skeleton -->

## Workstream E: lint

<!-- (skeleton :tags lint) -->

_1 holes, 1 marks, 1 ready. Generated by `swiss sync`; edits inside this block are lost._

- **vocab-claims** · lint · ready
  - [Makefile:78](Makefile#L78) · checks sources.d/ against vocab/*.txt; v2 checks claims at load, and lint-core takes its kinds from them.

<!-- /skeleton -->
