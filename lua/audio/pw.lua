-- pactl list short: already tab separated. The adapter only renames and
-- reorders, which is what an adapter looks like when the source got it right.
return {
	feed = function(line)
		local f = {}
		for w in line:gmatch("[^\t]+") do f[#f + 1] = w end
		if #f < 5 then return end
		k.emit("sink", f[2], "id=" .. f[1], "spec=" .. f[4],
		       "state=" .. f[5]:lower())
	end,
}
