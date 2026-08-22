-- A stand-in window manager adapter, until wm/hypr.lua exists.
--
-- An adapter returns a table. `feed` takes one line of the foreign format and
-- calls k.emit for each fact it recognizes. It keeps no state and holds no
-- descriptor: lines in, facts out.
return {
	feed = function(line)
		local mon, tag = line:match("^focus (%S+) (%d+)$")
		if mon then
			k.emit("focus", mon)
			k.emit("tag", mon, tag, "state=focused,occupied")
		end
		-- anything else is a line this adapter does not understand
	end,
}
