-- bluez, on the system bus. Two ways in, like every D-Bus adapter here: a
-- GetManagedObjects poll for what is true now, and InterfacesAdded,
-- InterfacesRemoved and PropertiesChanged for what changes after.
--
-- A device is one object path, and everything about it arrives in pieces:
-- the name with the device, the battery when it connects, one property at a
-- time after that. The record is kept here and the whole fact is republished.
local BLUEZ  = "org.bluez"
local DEVICE = "org.bluez.Device1"
local RADIO  = "org.bluez.Adapter1"
local BATT   = "org.bluez.Battery1"

-- kippsrv wraps every value as {type=, data=}, and busctl leaves a nested
-- container bare. One unwrap reads both.
local function v(x)
	if type(x) == "table" and type(x.type) == "string" then return x.data end
	return x
end

local dev, radio = {}, {}
local by_addr = {}                     -- address -> object path, for a command

local function mac(path)
	local m = path:match("/dev_([%x_]+)$")
	return m and (m:gsub("_", ":"))
end

local function hci(path)
	return path:match("^/org/bluez/(%w+)")
end

local function pub_dev(path)
	local d = dev[path]
	if not d then return end

	local state = d.connected and "connected" or (d.paired and "paired" or "seen")
	k.emit("bt", d.addr,
	       "name="    .. (d.name or ""),
	       "icon="    .. (d.icon or ""),
	       "state="   .. state,
	       "battery=" .. (d.battery or ""),
	       "radio="   .. (d.radio or ""))
end

local function pub_radio(path)
	local r = radio[path]
	if not r then return end

	local state = "off"
	if r.powered then state = r.discovering and "scanning" or "on" end
	k.emit("bt_radio", r.id,
	       "name="    .. (r.name or ""),
	       "address=" .. (r.address or ""),
	       "state="   .. state)
end

-- Properties of one interface of one object, however they arrived.
local function take(path, iface, props)
	if iface == DEVICE then
		local addr = mac(path)
		if not addr then return end

		local d = dev[path] or {addr = addr, radio = hci(path)}
		dev[path], by_addr[addr] = d, path

		d.name = v(props.Alias) or v(props.Name) or d.name
		d.icon = v(props.Icon) or d.icon
		if props.Connected then d.connected = v(props.Connected) end
		if props.Paired    then d.paired    = v(props.Paired)    end
		pub_dev(path)

	elseif iface == BATT then
		local d = dev[path]
		if not d then return end
		d.battery = v(props.Percentage) or d.battery
		pub_dev(path)

	elseif iface == RADIO then
		local r = radio[path] or {id = hci(path)}
		radio[path] = r

		r.name    = v(props.Alias) or v(props.Name) or r.name
		r.address = v(props.Address) or r.address
		if props.Powered     then r.powered     = v(props.Powered)     end
		if props.Discovering then r.discovering = v(props.Discovering) end
		pub_radio(path)
	end
end

-- An interface left. Battery1 goes when a headphone disconnects, and the
-- device itself goes when bluez forgets an unpaired one it stopped seeing.
local function gone(path, iface)
	local d = dev[path]

	if iface == DEVICE and d then
		k.drop("bt", d.addr)
		by_addr[d.addr], dev[path] = nil, nil
	elseif iface == BATT and d then
		d.battery = nil
		pub_dev(path)
	elseif iface == RADIO and radio[path] then
		k.drop("bt_radio", radio[path].id)
		radio[path] = nil
	end
end

local on_device = {
	CONNECT    = "Connect",
	DISCONNECT = "Disconnect",
	PAIR       = "Pair",
}

local function radio_path(id)
	for path, r in pairs(radio) do
		if not id or r.id == id then return path end
	end
end

return {
	feed = function(line)
		local m = k.json(line)
		if not m then return end
		local body = m.body

		if m.member == "InterfacesAdded" then
			local path = v(body[1])
			for iface, props in pairs(v(body[2]) or {}) do
				take(path, iface, v(props))
			end

		elseif m.member == "InterfacesRemoved" then
			local path = v(body[1])
			for _, iface in ipairs(v(body[2]) or {}) do
				gone(path, v(iface))
			end

		elseif m.member == "PropertiesChanged" then
			take(m.path, v(body[1]), v(body[2]) or {})

		elseif m.data then                    -- a GetManagedObjects poll
			for path, ifaces in pairs(m.data[1] or {}) do
				for iface, props in pairs(v(ifaces)) do
					take(path, iface, v(props))
				end
			end
		end
	end,

	-- The subject is the address, as it is on the wire. bluez holds the paths.
	command = function(m)
		local subj = (m.subj[1] or ""):upper()

		local member = on_device[m.kind]
		if member then
			local path = by_addr[subj]
			if not path then
				return nil, "badarg", "no device with that address"
			end
			return {dest = BLUEZ, path = path, iface = DEVICE, member = member}
		end

		if m.kind == "FORGET" then
			local path = by_addr[subj]
			if not path then
				return nil, "badarg", "no device with that address"
			end
			return {dest = BLUEZ, path = radio_path(dev[path].radio),
			        iface = RADIO, member = "RemoveDevice",
			        sig = "o", args = {path}}
		end

		if m.kind == "SCAN" then
			local on = subj == "ON"
			if not on and subj ~= "OFF" then
				return nil, "badarg", "SCAN takes on or off"
			end
			local path = radio_path(m.attr.radio)
			if not path then
				return nil, "badarg", "no such radio"
			end
			return {dest = BLUEZ, path = path, iface = RADIO,
			        member = on and "StartDiscovery" or "StopDiscovery"}
		end
	end,
}
