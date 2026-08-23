-- sway and i3. One JSON object a line, so this is an exec source with Lines
-- framing and no protocol work. The binary i3 IPC in lua/wm/i3.lua is the
-- other way to read the same window manager, and it needs an outbound request
-- before it says anything.
--
-- Three sources share this file: `swaymsg -t get_outputs -r` says which
-- monitor is focused, `swaymsg -t get_workspaces -r` says which tags exist,
-- and `swaymsg -m -t subscribe` streams the changes. kippsrv loads the
-- adapter once however many sources name it, so all three share this state.
local mon = nil          -- focused monitor
local focused = {}       -- the tag each monitor is on, so the last one clears
local seed = {}          -- JSON lines waiting for the end of the batch
local SEED_MAX = 4096    -- a stream never flushes, so this cannot grow

local function set_tag(m, id)
	local was = focused[m]
	if was == id then return end
	if was then k.emit("tag", m, was, "state=occupied") end
	focused[m] = id
	k.emit("tag", m, id, "state=focused,occupied")
end

local function set_mon(m)
	if not m or m == mon then return end
	mon = m
	k.emit("focus", m)
end

local function show(c)
	if not mon or not c then return end
	local id = c.app_id or c.window_properties and c.window_properties.class
	if id and id ~= "" then k.emit("app", mon, "id=" .. id) end
	if c.name then k.emit("title", mon, "text=" .. c.name) end
end

return {
	feed = function(line)
		local msg = k.json(line)

		-- Not one whole object, so it belongs to a seed that arrived over
		-- several lines. A stream never ends, so an unrecognised line kept
		-- here forever would corrupt the next decode.
		if type(msg) ~= "table" or msg.change == nil then
			if #seed >= SEED_MAX then
				seed = {}
				k.log("sway: seed overflowed, discarded")
			end
			seed[#seed + 1] = line
			return
		end

		local ws = msg.current
		if ws and ws.output then
			-- A workspace event. sway focuses a monitor by focusing a
			-- workspace on it, so `current.focused` is what moves both.
			--
			-- The three that arrive on one keypress are init, focus, empty:
			-- a new workspace exists and holds nothing, focus moves to it,
			-- and the one we left is removed. init says focused=false, so
			-- only focus emits, and empty takes the old fact away again.
			if msg.change == "empty" then
				if focused[ws.output] == ws.num then
					focused[ws.output] = nil
				end
				k.drop("tag", ws.output, ws.num)
			elseif ws.focused then
				set_mon(ws.output)
				set_tag(ws.output, ws.num)
			end
			return
		end

		local c = msg.container
		if c then
			if msg.change == "focus" or msg.change == "title" then
				show(c)
			elseif msg.change == "new" then
				k.event("win_open", c.id, "mon=" .. (mon or "?"),
				       "appid=" .. (c.app_id or ""))
				show(c)
			elseif msg.change == "close" then
				k.event("win_close", c.id)
			end
			return
		end

		-- A mode event carries the name in `change` itself.
		if msg.change ~= "" and msg.pango_markup ~= nil then
			k.emit("mode", msg.change)
		end
	end,

	-- A seed arrives as one JSON blob, over one line with `-r` and over many
	-- without it, so it is decoded when the batch ends.
	flush = function()
		if #seed == 0 then return end
		local list = k.json(table.concat(seed, "\n"))
		seed = {}
		if type(list) ~= "table" then return end

		-- sway says what each entry is. Guessing from the fields instead
		-- does not work: an output and a workspace both carry name, rect
		-- and focused, so a workspace would be read as a monitor and its
		-- number emitted as one.
		for _, e in ipairs(list) do
			if e.type == "output" then
				if e.focused then set_mon(e.name) end
			elseif e.type == "workspace" then
				if e.focused then
					set_mon(e.output)
					set_tag(e.output, e.num)
				elseif focused[e.output] ~= e.num then
					k.emit("tag", e.output, e.num, "state=occupied")
				end
			end
		end
	end,
}
