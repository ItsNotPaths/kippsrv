-- (hole passthrough) goes; a source file with no feed passes lines through.
-- For a program that prints kipp itself. Nothing is translated.
--
-- A line is a fact unless it carries event=1, which marks something that
-- happened: it is passed on, never stored, and the mark is removed.
--
-- A command belongs to this source when its verb starts with the source's
-- name, uppercased, and `_`. Source "wm" takes WM_LINE, and it goes to the
-- program as it came.

local function fields_of(line)
	local fields = {}
	for field in line:gmatch("[^\t]+") do fields[#fields + 1] = field end
	return fields
end

local protocol = {version = true, sync = true, stale = true}

function feed(line)
	local fields = fields_of(line)
	local kind = table.remove(fields, 1)
	if kind == nil or protocol[kind] then return end
	if kind == "drop" then return k.drop(table.unpack(fields)) end

	for i, field in ipairs(fields) do
		if field == "event=1" then
			table.remove(fields, i)
			return k.event(kind, table.unpack(fields))
		end
	end
	if kind == "error" then return k.event(kind, table.unpack(fields)) end
	k.emit(kind, table.unpack(fields))
end

function command(m, source)
	local prefix = source:upper() .. "_"
	if m.kind:sub(1, #prefix) ~= prefix then return nil end

	local fields = {m.kind}
	for _, subject in ipairs(m.subj) do fields[#fields + 1] = subject end
	for key, value in pairs(m.attr) do fields[#fields + 1] = key .. "=" .. value end
	return table.concat(fields, "\t") .. "\n"
end
