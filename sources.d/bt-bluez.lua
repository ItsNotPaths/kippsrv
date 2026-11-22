-- bluez, on the system bus. Two ways in, like every D-Bus adapter here: a
-- GetManagedObjects poll for what is true now, and InterfacesAdded,
-- InterfacesRemoved and PropertiesChanged from kippbus match for what changes
-- after. Requests go back out as call lines on the stream's stdin.
--
-- A device is one object path, and everything about it arrives in pieces:
-- the name with the device, the battery when it connects, one property at a
-- time after that. The record is kept here and the whole fact is republished.
local claim = {"bt/*", "bt_radio/*"}
source { name = "bt", retains = claim, takes = "bt/request",
         exec = [[kippbus match --system ]] ..
                [["type='signal',sender='org.bluez',interface='org.freedesktop.DBus.ObjectManager'" ]] ..
                [["type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties'"]] }
source { name = "bt-seed", retains = claim,
         exec = "busctl --system --json=short call org.bluez / " ..
                "org.freedesktop.DBus.ObjectManager GetManagedObjects" }

local BLUEZ   = "org.bluez"
local DEVICE  = "org.bluez.Device1"
local RADIO   = "org.bluez.Adapter1"
local BATTERY = "org.bluez.Battery1"

-- kippbus wraps every value as {type=, data=}, and busctl leaves a nested
-- container bare. One unwrap reads both.
local function value(wrapped)
	if type(wrapped) == "table" and type(wrapped.type) == "string" then return wrapped.data end
	return wrapped
end

-- A line for kippbus match: tab-separated, like kipp.
local function call(path, interface, member, signature, ...)
	return table.concat({"call", BLUEZ, path, interface, member, signature or "", ...}, "\t") .. "\n"
end

local devices, radios = {}, {}
local path_of_address = {}            -- for a request, which names the address

local function address_of(path)
	local address = path:match("/dev_([%x_]+)$")
	return address and (address:gsub("_", ":"))
end

local function radio_of(path)
	return path:match("^/org/bluez/(%w+)")
end

local function publish_device(path)
	local device = devices[path]
	if not device then return end

	local state = device.connected and "connected" or (device.paired and "paired" or "seen")
	k.retain("bt/" .. device.address,
	         "name="    .. (device.name or ""),
	         "icon="    .. (device.icon or ""),
	         "state="   .. state,
	         "battery=" .. (device.battery or ""),
	         "radio="   .. (device.radio or ""))
end

local function publish_radio(path)
	local radio = radios[path]
	if not radio then return end

	local state = "off"
	if radio.powered then state = radio.discovering and "scanning" or "on" end
	k.retain("bt_radio/" .. radio.id,
	         "name="    .. (radio.name or ""),
	         "address=" .. (radio.address or ""),
	         "state="   .. state)
end

-- Properties of one interface of one object, however they arrived.
local function take(path, interface, properties)
	if interface == DEVICE then
		local address = address_of(path)
		if not address then return end

		local device = devices[path] or {address = address, radio = radio_of(path)}
		devices[path], path_of_address[address] = device, path

		device.name = value(properties.Alias) or value(properties.Name) or device.name
		device.icon = value(properties.Icon) or device.icon
		if properties.Connected then device.connected = value(properties.Connected) end
		if properties.Paired    then device.paired    = value(properties.Paired)    end
		publish_device(path)

	elseif interface == BATTERY then
		local device = devices[path]
		if not device then return end
		device.battery = value(properties.Percentage) or device.battery
		publish_device(path)

	elseif interface == RADIO then
		local radio = radios[path] or {id = radio_of(path)}
		radios[path] = radio

		radio.name    = value(properties.Alias) or value(properties.Name) or radio.name
		radio.address = value(properties.Address) or radio.address
		if properties.Powered     then radio.powered     = value(properties.Powered)     end
		if properties.Discovering then radio.discovering = value(properties.Discovering) end
		publish_radio(path)
	end
end

-- An interface left. Battery1 goes when a headphone disconnects, and the
-- device itself goes when bluez forgets an unpaired one it stopped seeing.
local function gone(path, interface)
	local device = devices[path]

	if interface == DEVICE and device then
		k.retain("bt/" .. device.address)
		path_of_address[device.address], devices[path] = nil, nil
	elseif interface == BATTERY and device then
		device.battery = nil
		publish_device(path)
	elseif interface == RADIO and radios[path] then
		k.retain("bt_radio/" .. radios[path].id)
		radios[path] = nil
	end
end

local device_members = {
	connect    = "Connect",
	disconnect = "Disconnect",
	pair       = "Pair",
}

local function radio_path(id)
	for path, radio in pairs(radios) do
		if not id or radio.id == id then return path end
	end
end

function feed(line)
	local message = k.json(line)
	if not message then return end
	local body = message.body

	if message.member == "InterfacesAdded" then
		local path = value(body[1])
		for interface, properties in pairs(value(body[2]) or {}) do
			take(path, interface, value(properties))
		end

	elseif message.member == "InterfacesRemoved" then
		local path = value(body[1])
		for _, interface in ipairs(value(body[2]) or {}) do
			gone(path, value(interface))
		end

	elseif message.member == "PropertiesChanged" then
		take(message.path, value(body[1]), value(body[2]) or {})

	elseif message.data then                  -- a GetManagedObjects poll
		for path, interfaces in pairs(message.data[1] or {}) do
			for interface, properties in pairs(value(interfaces)) do
				take(path, interface, value(properties))
			end
		end
	end
end

-- publish bt/request action=connect|disconnect|pair|forget addr=<address>
-- publish bt/request action=scan state=on|off [radio=<id>]
-- The address is as it is on the wire. bluez holds the paths.
function request(message)
	local action = message.payload.action or ""
	local address = (message.payload.addr or ""):upper()

	local member = device_members[action]
	if member then
		local path = path_of_address[address]
		if not path then
			return nil, "badarg", "no device with that address"
		end
		return call(path, DEVICE, member)
	end

	if action == "forget" then
		local path = path_of_address[address]
		if not path then
			return nil, "badarg", "no device with that address"
		end
		return call(radio_path(devices[path].radio), RADIO, "RemoveDevice", "o", path)
	end

	if action == "scan" then
		local on = message.payload.state == "on"
		if not on and message.payload.state ~= "off" then
			return nil, "badarg", "scan takes state=on or off"
		end
		local path = radio_path(message.payload.radio)
		if not path then
			return nil, "badarg", "no such radio"
		end
		return call(path, RADIO, on and "StartDiscovery" or "StopDiscovery")
	end

	return nil, "badarg", "unknown action"
end
