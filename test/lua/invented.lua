-- A kind nobody agreed to. Nothing in kippsrv has heard of it.
return {
	feed = function(line)
		k.emit("solar_panel", "roof", "watts=412", "tilt=31")
	end,
}
