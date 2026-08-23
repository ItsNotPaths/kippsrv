-- MPRIS. One file, two ways in: a poll of `busctl ... GetAll`, or a live
-- PropertiesChanged signal. kippsrv gives both the JSON busctl prints, so
-- neither needs its own adapter.
--
-- Every D-Bus value arrives wrapped as {type=..., data=...}. Unwrapping is
-- most of this file, and that wrapping is exactly what kipp does not have.
local function v(x)
	return x and x.data
end

-- A signal carries only what changed, so the rest is remembered. One table
-- per player: two players sharing one would each overwrite the other.
local last = {}

local function publish(props, sender)
	local meta = v(props.Metadata)
	local who = sender

	if meta then
		local id = v(meta["mpris:trackid"]) or ""
		who = id:match("^/[%a]+/(%a+)/") or who
	end
	if not who then return end

	local p = last[who] or {}
	last[who] = p

	if meta then
		p.title  = v(meta["xesam:title"]) or p.title
		local a = v(meta["xesam:artist"])
		p.artist = (a and a[1]) or p.artist
		p.length = math.floor((v(meta["mpris:length"]) or 0) / 1000000)
	end
	p.status = v(props.PlaybackStatus) or p.status
	if not p.status then return end

	k.emit("media", who,
	       "status=" .. p.status,
	       "title="  .. (p.title or ""),
	       "artist=" .. (p.artist or ""),
	       "length=" .. (p.length or 0))

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
			publish(v(body[2]) or {}, msg.sender)
		elseif msg.data then
			publish(msg.data[1] or {}, "player")   -- a GetAll poll
		end
	end,
}
