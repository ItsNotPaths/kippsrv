-- The StatusNotifierWatcher's registration list.
--
-- The watcher owns a bus name, which only compiled code can do. What it
-- learns is desktop state like any other source, so it arrives here as JSON
-- and the kind is named in Lua. The core never says "tray".
--
-- This is the one place the outbound seam is not optional. An icon is
-- activated by calling a method on the connection it registered on, and that
-- connection is kippsrv's. Nothing else in the session can reach it.
local ITEM = "org.kde.StatusNotifierItem"

local verbs = {
	ACTIVATE  = {"Activate",          "ii"},
	SECONDARY = {"SecondaryActivate", "ii"},
	MENU      = {"ContextMenu",       "ii"},
	SCROLL    = {"Scroll",            "is"},
}

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

	-- The subject is what the item registered as: a bus name, then the object
	-- path on it. x and y are where the pointer was, which is what an item
	-- places its own menu against.
	command = function(m)
		local v = verbs[m.kind]
		if not v then return nil end

		local dest, path = (m.subj[1] or ""):match("^([^/]+)(/.+)$")
		if not dest then
			return nil, "badarg", "the subject is <bus name>/<object path>"
		end

		local args = {m.attr.x or "0", m.attr.y or "0"}
		if v[2] == "is" then
			local dir = m.attr.dir or "vertical"
			if dir ~= "vertical" and dir ~= "horizontal" then
				return nil, "badarg", "dir is vertical or horizontal"
			end
			args = {m.attr.delta or "0", dir}
		end

		return {dest = dest, path = path, iface = ITEM,
		        member = v[1], sig = v[2], args = args}
	end,
}
