-- Raw framing hands over whatever arrived, byte count and all.
return {
	feed = function(chunk)
		k.emit("chunk", "bytes=" .. #chunk)
	end,
}
