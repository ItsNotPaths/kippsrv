-- Hyprland. socket2 emits `event>>data`, comma separated, so a title holding
-- a comma is ambiguous. Split only as far as the format guarantees.
--
-- Hyprland identifies windows by address and the bar draws per monitor, so
-- this adapter tracks the focused monitor and resolves against it. That
-- resolution is the work an adapter exists to do.
-- Two sources share this file: `hyprctl monitors -j` seeds the current state
-- once, and socket2 streams the changes. kippsrv loads the adapter once and
-- attaches both sources to it, so they share this state.
local mon = nil          -- focused monitor
local focused = {}       -- the tag each monitor is on, so the last one clears
local pending = nil      -- appid/title seen before we knew the monitor
local seed = {}          -- JSON lines waiting for the end of the batch
local SEED_MAX = 4096    -- a live socket never flushes, so this cannot grow

local function split2(s)
	local a, b = s:match("^([^,]*),(.*)$")
	if a then return a, b end
	return s, nil
end

-- Focus moves. Saying the new tag is focused without saying the old one is
-- not leaves every tag ever visited focused, because the store keys on kind
-- plus subject and each tag is its own fact.
local function set_tag(m, id)
	local was = focused[m]
	if was == id then return end
	if was then k.emit("tag", m, was, "state=occupied") end
	focused[m] = id
	k.emit("tag", m, id, "state=focused,occupied")
end

local function show(appid, text)
	if not mon then
		pending = {appid, text}
		return
	end
	if appid and appid ~= "" then k.emit("app", mon, "id=" .. appid) end
	if text then k.emit("title", mon, "text=" .. text) end
end

return {
	feed = function(line)
		local ev, data = line:match("^([%a%d]+)>>(.*)$")
		if not ev then
			-- Not an event, so it belongs to the seed. A socket never ends,
			-- so an unrecognised line there would accumulate for the session
			-- and corrupt the next decode.
			if #seed >= SEED_MAX then
				seed = {}
				k.log("hypr: seed overflowed, discarded")
			end
			seed[#seed + 1] = line
			return
		end

		if ev == "focusedmon" then
			local m, ws = split2(data)
			mon = m
			k.emit("focus", m)
			if ws then set_tag(m, ws) end
			if pending then
				show(pending[1], pending[2])
				pending = nil
			end

		elseif ev == "workspacev2" then
			local id = split2(data)
			if mon then set_tag(mon, id) end

		elseif ev == "destroyworkspacev2" then
			-- Hyprland removes an empty workspace. The fact goes with it.
			local id = split2(data)
			for m, t in pairs(focused) do
				if t == id then focused[m] = nil end
			end
			if mon then k.drop("tag", mon, id) end

		elseif ev == "activewindow" then
			show(split2(data))

		elseif ev == "openwindow" then
			-- address,workspace,appid,title  and the title may hold commas
			local addr, r1 = split2(data)
			local ws, r2 = split2(r1 or "")
			local appid, title = split2(r2 or "")
			k.event("win_open", addr, "mon=" .. (mon or "?"),
			       "tag=" .. ws, "appid=" .. appid)
			show(appid, title)

		elseif ev == "closewindow" then
			k.event("win_close", data)

		elseif ev == "submap" then
			k.emit("mode", data ~= "" and data or "normal")
		end
	end,

	-- The seed arrives as one JSON blob over many lines, so it is decoded
	-- when the batch ends.
	flush = function()
		if #seed == 0 then return end
		local mons = k.json(table.concat(seed, "\n"))
		seed = {}
		if not mons then return end

		for _, m in ipairs(mons) do
			if m.focused then
				mon = m.name
				k.emit("focus", m.name)
			end
			local ws = m.activeWorkspace
			if ws then
				k.emit("tag", m.name, ws.id, "state=focused,occupied")
			end
		end
		if pending and mon then
			show(pending[1], pending[2])
			pending = nil
		end
	end,
}
