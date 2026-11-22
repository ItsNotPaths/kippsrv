-- A stand-in window manager adapter, for the tests. It declares no source.
--
-- `feed` takes one line of the foreign format and calls k.retain for each
-- value it recognizes. It keeps no state and holds no descriptor: lines in,
-- lines out.
function feed(line)
	local mon, tag = line:match("^focus (%S+) (%d+)$")
	if mon then
		k.retain("focus", "mon=" .. mon)
		k.retain("tag/" .. mon .. "/" .. tag, "state=focused,occupied")
	end
	-- anything else is a line this adapter does not understand
end
