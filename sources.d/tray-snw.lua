-- (hole kippbus-tray) goes; kippbus tray prints kipp itself.
-- The StatusNotifierWatcher's registration list.
--
-- The watcher owns a bus name, which only compiled code can do. What it
-- learns is desktop state like any other source, so it arrives here as JSON
-- and the kind is named in Lua. The core never says "tray".
--
-- This is the one place the outbound seam is not optional. An icon is
-- activated by calling a method on the connection it registered on, and that
-- connection is kippsrv's. Nothing else in the session can reach it.
-- Owning the name needs compiled code; naming the kind does not, so the
-- registrations arrive here like anything else.
source { name = "tray", watcher = true, retains = {"tray/*"}, takes = "tray/request" }

local ITEM = "org.kde.StatusNotifierItem"

local actions = {
	activate  = {"Activate",          "ii"},
	secondary = {"SecondaryActivate", "ii"},
	menu      = {"ContextMenu",       "ii"},
	scroll    = {"Scroll",            "is"},
}

function feed(line)
	local m = k.json(line)
	if not m then return end

	for _, it in ipairs(m.dropped or {}) do
		k.retain("tray/" .. it)
	end
	for _, it in ipairs(m.items or {}) do
		k.retain("tray/" .. it, "state=registered")
	end
end

-- publish tray/request action=activate item=<bus name>/<object path> x= y=
-- The item is what it registered as. x and y are where the pointer was,
-- which is what an item places its own menu against.
function request(m)
	local v = actions[m.payload.action or ""]
	if not v then return nil, "badarg", "unknown action" end

	local dest, path = (m.payload.item or ""):match("^([^/]+)(/.+)$")
	if not dest then
		return nil, "badarg", "item= is <bus name>/<object path>"
	end

	local args = {m.payload.x or "0", m.payload.y or "0"}
	if v[2] == "is" then
		local dir = m.payload.dir or "vertical"
		if dir ~= "vertical" and dir ~= "horizontal" then
			return nil, "badarg", "dir= is vertical or horizontal"
		end
		args = {m.payload.delta or "0", dir}
	end

	return {dest = dest, path = path, iface = ITEM,
	        member = v[1], sig = v[2], args = args}
end
