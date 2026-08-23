-- The StatusNotifierWatcher's registration list.
--
-- The watcher owns a bus name, which only compiled code can do. What it
-- learns is desktop state like any other source, so it arrives here as JSON
-- and the kind is named in Lua. The core never says "tray".
return {
	feed = function(line)
		local m = k.json(line)
		if not m then return end

		for _, it in ipairs(m.dropped or {}) do
			k.drop("tray", it)
		end
		for _, it in ipairs(m.items or {}) do
			k.emit("tray", it, "state=registered")
		end
	end,
}
