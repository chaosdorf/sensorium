local pm1006 = {}

function pm1006.parse_frame(data)
	if string.byte(data, 1) ~= 0x16 or string.byte(data, 2) ~= 0x11 or string.byte(data, 3) ~= 0x0b then
		-- invalid header
		return nil
	end
	local checksum = 0
	for i = 1, 20 do
		checksum = (checksum + string.byte(data, i)) % 256
	end
	if checksum ~= 0 then
		-- invalid checksum
		return nil
	end
	local pm2_5 = string.byte(data, 6) * 256 + string.byte(data, 7)
	return pm2_5
end

return pm1006
