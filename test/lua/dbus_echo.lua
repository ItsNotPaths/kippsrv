-- Echo a D-Bus signal back as one kipp fact, so the conversion can be seen.
return {
	feed = function(line)
		local m = k.json(line)
		if not m then return end
		local first = m.body and m.body[1]
		local props = m.body and m.body[2] and m.body[2].data
		k.emit("sig", m.member or "?",
		       "iface=" .. (m.interface or ""),
		       "s=" .. tostring(first and first.data),
		       "k1=" .. tostring(props and props.k1 and props.k1.data),
		       "k2=" .. tostring(props and props.k2 and props.k2.data))
	end,
}
