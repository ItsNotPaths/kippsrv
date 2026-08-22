-- Raw framing hands over whatever arrived, byte count and all.
return {
	feed = function(chunk)
		k.event("chunk", "bytes=" .. #chunk)
	end,
}
