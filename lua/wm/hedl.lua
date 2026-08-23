-- hedl speaks kipp already (its D13), so there is nothing to translate. This
-- file exists because kippsrv wants an adapter for every source, not because
-- the format needs one. It splits the line and hands the fields straight to
-- k.emit.
--
-- If this file ever grows a rule, the two formats have drifted, and the fix is
-- the format rather than the adapter.

-- Going the other way is a translation, because hedl takes the action names
-- its own key table uses, one to a line, on the FIFO the `cmd` path names.
--
-- `spawn` is deliberately absent. A consumer that wants to start a program
-- can start it, and putting it here would turn a socket anyone in this
-- session can reach into a way to run anything.
local verbs = {
	VIEW       = {"view",             "tag"},
	TAG        = {"tag",              "tag"},
	TOGGLEVIEW = {"toggleview",       "tag"},
	TOGGLETAG  = {"toggletag",        "tag"},
	LAYOUT     = {"setlayout",        "word"},
	FOCUS      = {"focusstack",       "num"},
	MONITOR    = {"focusmon",         "num"},
	MOVE       = {"tagmon",           "num"},
	MASTER     = {"setmfact",         "num"},
	NMASTER    = {"incnmaster",       "num"},
	CLOSE      = {"killclient"},
	ZOOM       = {"zoom"},
	FLOAT      = {"togglefloating"},
	FULLSCREEN = {"togglefullscreen"},
	RELOAD     = {"reload"},
	QUIT       = {"quit"},
}

return {
	feed = function(line)
		local f = {}
		for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
		if #f < 2 then return end        -- version and sync carry no fact
		local kind = table.remove(f, 1)
		if kind == "version" or kind == "sync" then return end
		k.emit(kind, table.unpack(f))
	end,

	-- A subject field cannot hold a tab or a newline: the line it came from
	-- was split on both. So the argument goes out as it arrived and there is
	-- nothing to escape.
	command = function(m)
		local v = verbs[m.kind]
		if not v then return nil end
		if not v[2] then return v[1] .. "\n" end

		local arg = m.subj[1]
		if not arg then return nil, "badarg", m.kind .. " needs an argument" end

		local n = tonumber(arg)
		if v[2] == "num" and not n then
			return nil, "badarg", m.kind .. " takes a number"
		end
		if v[2] == "tag" and (not n or n < 1 or n > 9 or n % 1 ~= 0) then
			return nil, "badarg", m.kind .. " takes a tag, 1 to 9"
		end
		return v[1] .. "\t" .. arg .. "\n"
	end,
}
