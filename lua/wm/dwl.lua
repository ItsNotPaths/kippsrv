-- dwl printstatus: `<monitor> <kind> <data...>`, space separated, so the
-- title has to be last.
--
-- dwl reports tags as three bitmasks. kipp reports one line for each tag that
-- is not empty, which is what a bar draws. Expanding the mask is this file's
-- job, not the bar's.
local function bit(mask, n)
	return math.floor(mask / 2 ^ (n - 1)) % 2 == 1
end

return {
	feed = function(line)
		local mon, kind, data = line:match("^(%S+)%s+(%S+)%s*(.*)$")
		if not mon then return end

		if kind == "title" then
			k.emit("title", mon, data)

		elseif kind == "appid" then
			k.emit("app", mon, data)

		elseif kind == "tags" then
			local occ, sel, urg = data:match("^(%d+)%s+(%d+)%s+(%d+)")
			occ, sel, urg = tonumber(occ) or 0, tonumber(sel) or 0, tonumber(urg) or 0
			for n = 1, 9 do
				local state = {}
				if bit(sel, n) then state[#state + 1] = "focused" end
				if bit(occ, n) then state[#state + 1] = "occupied" end
				if bit(urg, n) then state[#state + 1] = "urgent" end
				if #state > 0 then
					k.emit("tag", mon, n, "state=" .. table.concat(state, ","))
				end
			end

		elseif kind == "layout" then
			k.emit("layout", mon, data)

		elseif kind == "selmon" then
			if data == "1" then k.emit("focus", mon) end
		end
	end,
}
