-- MPRIS. One file, two ways in: a poll of `busctl ... GetAll`, or a live
-- PropertiesChanged signal from kippbus match. Both arrive as the JSON busctl
-- prints, so neither needs its own adapter.
--
-- Every D-Bus value arrives wrapped as {type=..., data=...}. Unwrapping is
-- most of this file, and that wrapping is exactly what kipp does not have.
source { name = "media", retains = "media/*",
         exec = [[kippbus match "type='signal',interface='org.freedesktop.DBus.Properties',]] ..
                [[member='PropertiesChanged',path='/org/mpris/MediaPlayer2'"]] }

local function value(wrapped)
	return wrapped and wrapped.data
end

-- A signal carries only what changed, so the rest is remembered. One table
-- per player: two players sharing one would each overwrite the other.
local players = {}

local function publish(properties, sender)
	local metadata = value(properties.Metadata)
	local player_name = sender

	if metadata then
		local track = value(metadata["mpris:trackid"]) or ""
		player_name = track:match("^/[%a]+/(%a+)/") or player_name
	end
	if not player_name then return end

	local player = players[player_name] or {}
	players[player_name] = player

	if metadata then
		player.title  = value(metadata["xesam:title"]) or player.title
		local artists = value(metadata["xesam:artist"])
		player.artist = (artists and artists[1]) or player.artist
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

	if message.member == "PropertiesChanged" then
		local body = message.body
		local interface = body and body[1] and body[1].data
		if interface ~= "org.mpris.MediaPlayer2.Player" then return end
		publish(value(body[2]) or {}, message.sender)
	elseif message.data then
		-- (hole media-seed :tags lua :sev gap) no source polls GetAll, so a player already playing shows nothing until it changes.
		publish(message.data[1] or {}, "player")
	end
end
