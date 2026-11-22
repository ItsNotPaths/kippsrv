-- A timer source calls `tick`. It carries no data, so the adapter reads
-- whatever it needs when asked.
local n = 0
function tick()
	n = n + 1
	k.publish("beat/test", "count=" .. n)
end
