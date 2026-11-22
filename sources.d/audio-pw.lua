-- (hole adapters-v2 :tags lua) emits v1 kinds.
-- pactl list short: already tab separated. The adapter only renames and
-- reorders, which is what an adapter looks like when the source got it right.
-- throttle = false: a person drives this. Backing off would mean pressing the
-- volume key and waiting up to 32 s for the bar to notice.
source { name = "audio", exec = "pactl list short sinks", every = 2000, throttle = false,
         retains = {"sink/*"} }

function feed(line)
	local f = {}
	for w in line:gmatch("[^\t]+") do f[#f + 1] = w end
	if #f < 5 then return end
	k.emit("sink", f[2], "id=" .. f[1], "spec=" .. f[4],
	       "state=" .. f[5]:lower())
end
