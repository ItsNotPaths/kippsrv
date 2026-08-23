# What kippsrv is telling you

Every message with a code in brackets is listed here. Each says who can fix it.

**If a message says it is a bug in an adapter**, it is not something you can
correct in `config.lua`. Report it to whoever maintains that file, and quote
the whole message: it names the file and the exact field that caused it.

---

## E-subject — an adapter produced a fact with no identity

Something is missing from your desktop. One entry of that kind was dropped.

*For the adapter's maintainer.* A fact is identified by its kind and its
subject fields. The framing rule reads the first field holding `=` as the start
of the attributes, so a subject holding one leaves the fact with no subject at
all. Its key becomes the bare kind, and it would overwrite every other fact of
that kind.

Use a subject that cannot hold `=`: a UUID, a MAC, a bus name, a device path.
Move the readable name to an attribute, where `=` is legal. Only the first one
separates a key from its value, so `name=home=wifi` is fine.

```lua
k.emit("net", "home=wifi", "type=wifi")            -- wrong
k.emit("net", uuid, "name=home=wifi", "type=wifi") -- right
```

An event is exempt. It is never stored, so it needs no identity.

## E-toolong — an adapter produced a fact over 1024 bytes

That one fact was dropped. Everything else is unaffected.

*For the adapter's maintainer.* 1024 bytes is the line limit in kipp's
`SPEC.md`. A window title or a media title can reach it. Truncate the field
before emitting it.

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

## E-name — the tray name could not be taken

The tray will stay empty. Nothing else is affected.

*This one you can usually fix.* Some other program owns
`org.kde.StatusNotifierWatcher` — a shell like Quickshell, waybar with its own
watcher, or a second kippsrv. Stop it, restart kippsrv, then restart every
application with a tray icon: an application looks for the watcher once, at its
own startup, and never again.

If the message says a name was *refused*, `config.lua` has more than one source
with `watcher = true`. Only the first starts. Keep one.

## E-bus — a source could not reach D-Bus, or its match was refused

Whatever that source reports is missing. Everything else keeps working.

*Usually the environment.* A session bus needs `DBUS_SESSION_BUS_ADDRESS` set,
which a desktop session normally does. A refused match rule is a bug in the
rule itself, in `config.lua`.

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
