-- nmcli -t: colon separated, and a field holding a colon escapes it as `\:`.
-- Splitting on a bare colon is wrong, which is the reason kipp uses a byte a
-- value may never hold.
source { name = "net", exec = "nmcli -t -f UUID,NAME,TYPE,DEVICE connection show", every = 5000,
         retains = {"net/*"} }

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

function feed(line)
	local f = split_esc(line)
	if #f < 4 or f[1] == "" then return end

	-- The topic is the UUID. The device is empty for every inactive
	-- connection, so keying on it collapses them onto one value. The name
	-- is unique but a person types it, so it goes in the payload.
	k.retain("net/" .. f[1],
	         "name=" .. f[2], "type=" .. f[3],
	         "device=" .. f[4],
	         "state=" .. (f[4] ~= "" and "up" or "down"))
end
