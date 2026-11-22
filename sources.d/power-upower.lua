-- upower --dump: one indented multi-line record per device. Two-space
-- `key: value` is the device, a bare word opens a section, four-space pairs
-- belong to it.
--
-- throttle = false: a person plugs the charger in and expects the bar to
-- notice within seconds.
source { name = "power", exec = "upower --dump", every = 5000, throttle = false,
         retains = "power/*" }

-- (hole power-stream :tags sources :sev polish) polls upower --dump; UPower's D-Bus signals would push changes, but each device needs its own GetAll.

-- One value needs many lines, so this adapter holds state between feeds. A
-- file's locals live as long as its sources. The last record needs `flush`,
-- because the format has no terminator.
local dev, sect, fields = nil, nil, {}

local function retain_device()
	if not dev then return end
	local payload = {}
	for _, key in ipairs({"state", "percentage", "battery-level", "warning-level", "online"}) do
		if fields[key] then
			payload[#payload + 1] = key:gsub("%-", "_") .. "=" .. fields[key]
		end
	end
	if sect then payload[#payload + 1] = "kind=" .. sect end
	k.retain("power/" .. dev, table.unpack(payload))
	dev, sect, fields = nil, nil, {}
end

function feed(line)
	local indent, body = line:match("^(%s*)(.-)%s*$")
	if body == "" then return retain_device() end

	local key, val = body:match("^([%w%-%s]-):%s*(.*)$")
	if key then
		key = key:gsub("%s+$", "")
		if key == "Device" then
			-- a new record. DisplayDevice, upower's sum of the batteries, has no
			-- native-path, so it is skipped
			retain_device()
		elseif #indent <= 2 then
			if key == "native-path" then
				retain_device()
				dev = val
			end
		else
			val = val:gsub("^'(.*)'$", "%1"):gsub("%s*%(.*%)$", "")
			fields[key] = val
		end
	elseif #indent <= 2 and body:match("^[%w%-]+$") then
		sect = body           -- a bare word opens a section; `History (rate):` is not one
	end
end

flush = retain_device
