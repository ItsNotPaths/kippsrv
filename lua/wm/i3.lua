-- i3 and sway. A length-prefixed binary frame: a magic string, a
-- 32-bit little-endian length, a 32-bit type, then a JSON payload.
--
-- The source hands over whole frames. Buffering a partial one is its job,
-- the same way it already joins a partial line. This file only reads what a
-- frame holds, which is the part that is specific to the format.
local MAGIC = "i3-ipc"

return {
	feed = function(frame)
		if frame:sub(1, #MAGIC) ~= MAGIC then return end

		local len, kind, pos = string.unpack("<I4<I4", frame, #MAGIC + 1)
		local body = k.json(frame:sub(pos, pos + len - 1))
		if not body then return end

		if kind == 1 then                       -- GET_WORKSPACES
			for _, ws in ipairs(body) do
				local state = ws.focused and "focused,occupied" or "occupied"
				k.emit("tag", ws.output, ws.num, "state=" .. state)
				if ws.focused then k.emit("focus", ws.output) end
			end
		elseif kind == 3 then                   -- GET_OUTPUTS
			for _, o in ipairs(body) do
				if o.active and o.current_workspace then
					k.emit("focus", o.name)
				end
			end
		end
	end,
}
