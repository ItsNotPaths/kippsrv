-- What org.freedesktop.Notifications received.
--
-- The name is owned by compiled code, because only compiled code can own one.
-- What arrives on it is desktop state like any other source, so it comes here
-- as JSON and the kind is named in Lua. The core never says "notification".
--
--   notif  <id>  app=grim  summary=Screenshot saved  body=...
--                urgency=normal  read=0  icon=/path.png
--                action=open  exec=satty -f /home/x/Pictures/a.png
--
-- The two verbs go back out the way the tray's do: a method call on the bus
-- kippsrv already holds. Closing is the spec's own; being read is ours, on our
-- own interface, because a spec notification is a toast nobody chose to see.
--
-- The call names org.freedesktop.Notifications, which is kippsrv itself: the
-- bus routes by destination, so it arrives back at the vtable that owns the
-- state. A source started under `bus_name` to test beside a live daemon is the
-- one case where that lands on the other one, so test those two verbs by
-- calling the members directly.
local FDO  = "org.freedesktop.Notifications"
local PATH = "/org/freedesktop/Notifications"
local OURS = "place.paths.kippsrv.Notifications"

-- The spec numbers urgency and every consumer wants the word.
local URGENCY = {[0] = "low", [1] = "normal", [2] = "critical"}

return {
	feed = function(line)
		local m = k.json(line)
		if not m then return end

		-- A closed notification is gone, not stale. Say so, or the store
		-- keeps handing out the last thing anybody knew about it.
		for _, id in ipairs(m.dropped or {}) do
			k.drop("notif", tostring(id))
		end

		for _, one in ipairs(m.live or {}) do
			k.emit("notif", tostring(one.id),
			       "app=" .. (one.app or ""),
			       "summary=" .. (one.summary or ""),
			       "body=" .. (one.body or ""),
			       "icon=" .. (one.icon or ""),
			       "action=" .. (one.action or ""),
			       "exec=" .. (one.exec or ""),
			       "urgency=" .. (URGENCY[one.urgency] or "normal"),
			       "read=" .. (one.read and "1" or "0"))
		end
	end,

	command = function(m)
		if m.kind == "NOTIFY-CLOSE" then
			local id = tonumber(m.subj[1] or "")
			if not id then
				return nil, "badarg", "NOTIFY-CLOSE takes a notification id"
			end
			return {dest = FDO, path = PATH, iface = FDO,
			        member = "CloseNotification", sig = "u", args = {tostring(id)}}
		end

		if m.kind == "NOTIFY-READ" then
			return {dest = FDO, path = PATH, iface = OURS,
			        member = "MarkAllRead", sig = "", args = {}}
		end

		return nil
	end,
}
