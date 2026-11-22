-- (hole adapters-v2) emits v1 kinds.
-- A stand-in window manager adapter, for the tests. It declares no source.
--
-- `feed` takes one line of the foreign format and calls k.emit for each fact
-- it recognizes. It keeps no state and holds no descriptor: lines in, facts
-- out.
function feed(line)
	local mon, tag = line:match("^focus (%S+) (%d+)$")
	if mon then
		k.emit("focus", mon)
		k.emit("tag", mon, tag, "state=focused,occupied")
	end
	-- anything else is a line this adapter does not understand
end
