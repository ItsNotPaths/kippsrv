-- upower -i: an indented multi-line record. Two-space `key: value` is the
-- device, a bare word opens a section, four-space pairs belong to it.
--
-- One fact needs many lines, so this adapter holds state between feeds. The
-- table an adapter returns lives for the life of the source, so an upvalue
-- works. The last record needs `flush`, because the format has no terminator.
local dev, sect, fields = nil, nil, {}

local function emit_device()
	if not dev then return end
	local args = {dev}
	for _, key in ipairs({"state", "percentage", "battery-level", "warning-level"}) do
		if fields[key] then
			args[#args + 1] = key:gsub("%-", "_") .. "=" .. fields[key]
		end
	end
	if sect then args[#args + 1] = "kind=" .. sect end
	k.emit("power", table.unpack(args))
	dev, sect, fields = nil, nil, {}
end

return {
	feed = function(line)
		local indent, body = line:match("^(%s*)(.-)%s*$")
		if body == "" then return emit_device() end

		local key, val = body:match("^([%w%-%s]-):%s*(.*)$")
		if key then
			key = key:gsub("%s+$", "")
			if #indent <= 2 then
				if key == "native-path" then
					emit_device()
					dev = val
				end
			else
				val = val:gsub("^'(.*)'$", "%1"):gsub("%s*%(.*%)$", "")
				fields[key] = val
			end
		elseif #indent <= 2 then
			sect = body           -- a bare word opens a section
		end
	end,

	flush = emit_device,
}
