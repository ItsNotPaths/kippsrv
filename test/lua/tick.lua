-- A timer source calls `tick`. It carries no data, so the adapter reads
-- whatever it needs when asked.
local n = 0
return {
	tick = function()
		n = n + 1
		k.emit("beat", "test", "count=" .. n)
	end,
}
