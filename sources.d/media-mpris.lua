-- MPRIS. kippbus match tracks each player's bus name: a player already on the
-- bus at start, or one that arrives, is asked GetAll, and PropertiesChanged
-- follows. Both arrive as the JSON busctl prints.
--
-- Every D-Bus value arrives wrapped as {type=..., data=...}. Unwrapping is
-- most of this file, and that wrapping is exactly what kipp does not have.
local NAMESPACE = "org.mpris.MediaPlayer2"
local GET_ALL   = "/org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties GetAll s org.mpris.MediaPlayer2.Player"
local CHANGED   = "type='signal',interface='org.freedesktop.DBus.Properties'," ..
                  "member='PropertiesChanged',path='/org/mpris/MediaPlayer2'"
source { name = "media", retains = "media/*",
         exec = ('kippbus match --names %s --each "%s" "%s"'):format(NAMESPACE, GET_ALL, CHANGED) }

local function value(wrapped)
	return wrapped and wrapped.data
end

-- org.mpris.MediaPlayer2.firefox.instance_1_719 is firefox/instance_1_719:
-- each instance owns its own topic. playerctld only mirrors another player,
-- so it is not one of its own.
local function player_of(name)
	local player_name = (name or ""):sub(#NAMESPACE + 2):gsub("%.", "/")
	if player_name ~= "" and player_name:match("^[^/]+") ~= "playerctld" then return player_name end
end

-- A signal carries only what changed, so the rest is remembered. One table
-- per player: two players sharing one would each overwrite the other.
local players = {}

local function publish(player_name, properties)
	local player = players[player_name] or {}
	players[player_name] = player

	local metadata = value(properties.Metadata)
	if metadata then
		player.title  = value(metadata["xesam:title"]) or player.title
		local artists = value(metadata["xesam:artist"])
		player.artist = value(artists and artists[1]) or player.artist
		player.length = math.floor((value(metadata["mpris:length"]) or 0) / 1000000)
	end
	player.status = value(properties.PlaybackStatus) or player.status
	if not player.status then return end

	k.retain("media/" .. player_name,
	         "status=" .. player.status,
	         "title="  .. (player.title or ""),
	         "artist=" .. (player.artist or ""),
	         "length=" .. (player.length or 0))

	-- Position is deliberately not published. It moves every poll, so it
	-- would defeat the store and wake every consumer for nothing. A value
	-- that churns belongs on its own kind, or nowhere.
end

function feed(line)
	local message = k.json(line)
	if not message then return end
	local player_name = player_of(message.name)
	if not player_name then return end

	if message.type == "left" then
		players[player_name] = nil
		k.delete("media/" .. player_name)
	elseif message.type == "method_return" then
		publish(player_name, value(message.body[1]) or {})
	elseif message.member == "PropertiesChanged" then
		local body = message.body
		if value(body[1]) ~= "org.mpris.MediaPlayer2.Player" then return end
		publish(player_name, value(body[2]) or {})
	end
end
