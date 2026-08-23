-- MPRIS. One file, two ways in: a poll of `busctl ... GetAll`, or a live
-- PropertiesChanged signal. kippsrv gives both the JSON busctl prints, so
-- neither needs its own adapter.
--
-- Every D-Bus value arrives wrapped as {type=..., data=...}. Unwrapping is
-- most of this file, and that wrapping is exactly what kipp does not have.
local function v(x)
	return x and x.data
end

local last = {}          -- a signal carries only what changed

local function publish(props)
	local meta = v(props.Metadata)
	if meta then
		last.title  = v(meta["xesam:title"]) or last.title
		local a = v(meta["xesam:artist"])
		last.artist = (a and a[1]) or last.artist
		last.length = math.floor((v(meta["mpris:length"]) or 0) / 1000000)
		local id = v(meta["mpris:trackid"]) or ""
		last.who = id:match("^/[%a]+/(%a+)/") or last.who
	end
	last.status = v(props.PlaybackStatus) or last.status
	if not last.status then return end

	k.emit("media", last.who or "player",
	       "status=" .. last.status,
	       "title="  .. (last.title or ""),
	       "artist=" .. (last.artist or ""),
	       "length=" .. (last.length or 0))

	-- Position is deliberately not published. It moves every poll, so it
	-- would defeat the store and wake every consumer for nothing. A value
	-- that churns belongs on its own kind, or nowhere.
end

return {
	feed = function(line)
		local msg = k.json(line)
		if not msg then return end

		if msg.member == "PropertiesChanged" then
			local body = msg.body
			local iface = body and body[1] and body[1].data
			if iface ~= "org.mpris.MediaPlayer2.Player" then return end
			publish(v(body[2]) or {})
		elseif msg.data then
			publish(msg.data[1] or {})       -- a GetAll poll
		end
	end,
}
