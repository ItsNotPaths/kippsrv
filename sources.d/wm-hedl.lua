-- (hole passthrough) hedl speaks kipp already; a source file with no feed replaces this.
-- hedl speaks kipp already (its D13), so there is nothing to translate. This
-- file exists because kippsrv wants an adapter for every source, not because
-- the format needs one. It splits the line and hands the fields straight to
-- k.emit.
--
-- If this file ever grows a rule, the two formats have drifted, and the fix is
-- the format rather than the adapter.

-- Going the other way is a translation, because hedl takes the action names
-- its own key table uses, one to a line, on its stdin.
--
-- `spawn` is deliberately absent. A consumer that wants to start a program
-- can start it, and putting it here would turn a socket anyone in this
-- session can reach into a way to run anything.
-- action = {hedl's name, the key its argument comes in}
local actions = {
	view       = {"view",             "tag"},
	tag        = {"tag",              "tag"},
	toggleview = {"toggleview",       "tag"},
	toggletag  = {"toggletag",        "tag"},
	layout     = {"setlayout",        "name"},
	focus      = {"focusstack",       "by"},
	monitor    = {"focusmon",         "by"},
	move       = {"tagmon",           "by"},
	master     = {"setmfact",         "by"},
	nmaster    = {"incnmaster",       "by"},
	close      = {"killclient"},
	zoom       = {"zoom"},
	float      = {"togglefloating"},
	fullscreen = {"togglefullscreen"},
	reload     = {"reload"},
	quit       = {"quit"},
}

function feed(line)
	local f = {}
	for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
	if #f < 2 then return end        -- version and sync carry no fact
	local kind = table.remove(f, 1)
	if kind == "version" or kind == "sync" then return end
	k.emit(kind, table.unpack(f))
end

-- publish wm/request action=view tag=2. A payload value cannot hold a tab or
-- a newline, so the argument goes out as it arrived.
function request(m)
	local v = actions[m.payload.action or ""]
	if not v then return nil, "badarg", "unknown action" end
	if not v[2] then return v[1] .. "\n" end

	local arg = m.payload[v[2]]
	if not arg then return nil, "badarg", v[2] .. "= is missing" end

	local n = tonumber(arg)
	if v[2] == "by" and not n then return nil, "badarg", "by= takes a number" end
	if v[2] == "tag" and (not n or n < 1 or n > 9 or n % 1 ~= 0) then
		return nil, "badarg", "tag= takes a tag, 1 to 9"
	end
	return v[1] .. "\t" .. arg .. "\n"
end
