-- hedl speaks kipp already (its D13), so there is nothing to translate. This
-- file exists because kippsrv wants an adapter for every source, not because
-- the format needs one. It splits the line and hands the fields straight to
-- k.emit.
--
-- If this file ever grows a rule, the two formats have drifted, and the fix is
-- the format rather than the adapter.
return {
	feed = function(line)
		local f = {}
		for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
		if #f < 2 then return end        -- version and sync carry no fact
		local kind = table.remove(f, 1)
		if kind == "version" or kind == "sync" then return end
		k.emit(kind, table.unpack(f))
	end,
}
