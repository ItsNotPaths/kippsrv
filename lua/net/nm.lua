-- nmcli -t: colon separated, and a field holding a colon escapes it as `\:`.
-- Splitting on a bare colon is wrong, which is the reason kipp uses a byte a
-- value may never hold.
local function split_esc(s)
	local out, cur, i = {}, "", 1
	while i <= #s do
		local ch = s:sub(i, i)
		if ch == "\\" then
			cur = cur .. s:sub(i + 1, i + 1)
			i = i + 2
		elseif ch == ":" then
			out[#out + 1] = cur
			cur = ""
			i = i + 1
		else
			cur = cur .. ch
			i = i + 1
		end
	end
	out[#out + 1] = cur
	return out
end

return {
	feed = function(line)
		local f = split_esc(line)
		if #f < 4 or f[1] == "" then return end

		-- The subject is the UUID. The device is empty for every inactive
		-- connection, so keying on it collapses them onto one fact. The name
		-- is unique but a person types it, and a name holding '=' would be
		-- read as an attribute and lose the subject entirely. A UUID can hold
		-- neither problem.
		k.emit("net", f[1],
		       "name=" .. f[2], "type=" .. f[3],
		       "device=" .. (f[4] ~= "" and f[4] or ""),
		       "state=" .. (f[4] ~= "" and "up" or "down"))
	end,
}
