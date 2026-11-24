-- dwl printstatus: `<monitor> <kind> <data...>`, space separated, so the
-- title has to be last.
--
-- dwl reports tags as four bitmasks: occupied, selected, the focused window's
-- tags, urgent. kipp reports one line for each tag that is not empty, which is
-- what a bar draws, and deletes it when it empties. Expanding the mask is this
-- file's job, not the bar's.
-- Off, like every window manager. dwl hands its status to one child, so
-- kippsrv is that child.
--source { name = "wm", exec = "dwl -s cat",
--         retains = {"focus", "tags/*", "tag/*", "layout/*", "title/*", "app/*", "mode/*"} }

local function bit(mask, n)
	return math.floor(mask / 2 ^ (n - 1)) % 2 == 1
end

function feed(line)
	local mon, kind, data = line:match("^(%S+)%s+(%S+)%s*(.*)$")
	if not mon then return end

	if kind == "title" then
		k.retain("title/" .. mon, "text=" .. data)

	elseif kind == "appid" then
		k.retain("app/" .. mon, "id=" .. data)

	elseif kind == "tags" then
		local occ, sel, urg = data:match("^(%d+)%s+(%d+)%s+%d+%s+(%d+)")
		occ, sel, urg = tonumber(occ) or 0, tonumber(sel) or 0, tonumber(urg) or 0
		for n = 1, 9 do
			local state = {}
			if bit(sel, n) then state[#state + 1] = "focused" end
			if bit(occ, n) then state[#state + 1] = "occupied" end
			if bit(urg, n) then state[#state + 1] = "urgent" end
			if #state > 0 then
				k.retain("tag/" .. mon .. "/" .. n, "state=" .. table.concat(state, ","))
			else
				k.delete("tag/" .. mon .. "/" .. n)
			end
		end

	elseif kind == "layout" then
		k.retain("layout/" .. mon, "name=" .. data)

	elseif kind == "selmon" then
		if data == "1" then k.retain("focus", "mon=" .. mon) end
	end
end
