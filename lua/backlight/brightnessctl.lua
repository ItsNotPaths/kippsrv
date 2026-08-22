-- brightnessctl -m: `device,class,value,percent,max`, comma separated.
return {
	feed = function(line)
		local f = {}
		for w in line:gmatch("[^,]+") do f[#f + 1] = w end
		if #f < 5 then return end
		k.emit("backlight", f[1], "class=" .. f[2], "value=" .. f[3],
		       "percent=" .. f[4]:gsub("%%", ""), "max=" .. f[5])
	end,
}
