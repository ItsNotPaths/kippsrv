# What kippsrv is telling you

Every message with a code in brackets is listed here. Each says who can fix it.

**If a message says it is a bug in an adapter**, it is not something you can
correct in `config.lua`. Report it to whoever maintains that file, and quote
the whole message: it names the file and the exact field that caused it.

---

## E-word — an adapter produced a line that is not kipp

That one line was dropped. Everything else is unaffected.

*For the adapter's maintainer.* A topic's kind and every payload key are
words of lowercase letters, digits and underscores, and never a number. The
rest of a topic holds no `*`, `?` or `[`. Every field after the topic is
`key=value`. This is kipp's `SPEC.md`. A reader takes anything else apart
wrongly or not at all, so kippsrv keeps it off the socket. The message names
the topic or field at fault.

```lua
k.retain("net/" .. uuid, "home")            -- wrong: no '='
k.retain("net/" .. uuid, "name=home")       -- right
```

A program that prints kipp through a file with no `feed` is held to the same
rules.

## E-toolong — an adapter produced a line over 1024 bytes

That one line was dropped. Everything else is unaffected.

*For the adapter's maintainer.* 1024 bytes is the line limit in kipp's
`SPEC.md`. A window title or a media title can reach it. Truncate the field
before passing it.

## E-cmdemit — an adapter emitted a fact while taking a command

Those lines were dropped. The command itself was carried out.

*For the adapter's maintainer.* A command produces no facts. `SPEC.md` says a
command that succeeds gets no answer, and the state that follows the action is
what shows it happened. An adapter that emits here is guessing at a result it
has not seen yet, and the source it drives will report the real one a moment
later.

Return the bytes, the call, or the refusal. Emit nothing.

## E-full — the store is full

Parts of your desktop have stopped updating. Restarting kippsrv clears it, and
it will fill again.

*For the adapter's maintainer.* An adapter is using something unbounded as a
subject, so every new value becomes a new fact instead of updating one. The
usual cause is putting a value where an identity belongs: a title, a
percentage, a timestamp. Key on the thing, and put what changes in an
attribute.

## E-sources — more sources than kippsrv can watch

Some sources are not being read at all, so whatever they report is missing.

*This one you can fix.* Remove sources from `config.lua`, or merge several
polls into one command.

## E-name — kippbus could not take its name

From `kippbus tray` the tray stays empty, and from `kippbus notify` no
notification reaches the panel. Nothing else is affected.

*This one you can usually fix.* Some other program owns the name — for the
tray a shell like Quickshell, waybar with its own watcher, or a second kippbus;
for notifications dunst, mako or a desktop shell. Stop it and restart kippsrv.
For the tray, restart every application with a tray icon too: an application
looks for the watcher once, at its own startup, and never again.

## E-bus — kippbus could not reach D-Bus, its match was refused, or the bus dropped

Whatever that source reports is missing. Everything else keeps working.

*Usually the environment.* A session bus needs `DBUS_SESSION_BUS_ADDRESS` set,
which a desktop session normally does. A refused match rule is a bug in the
rule itself, on the `kippbus match` line of that source file.

## E-framing — a source and its framing do not agree

That source stopped, or its output was discarded. Everything else keeps
working.

*This one you can fix.* The `framing` block for that source in `config.lua`
does not describe what the command or socket actually produces. Remove the
block to fall back to lines, which is right for nearly every text tool.

---

## Messages without a code

Anything starting `config:` is about `config.lua` and is yours to correct. The
message names the key and what it expected.
