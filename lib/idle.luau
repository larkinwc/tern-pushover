--!strict
-- How long the Mac has had no keyboard or mouse input, from `ioreg -c IOHIDSystem`.

local M = {}

M.ARGV = { "/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4" }

-- Seconds since the last input, or nil when the output has no HIDIdleTime (nanoseconds).
function M.parse(ioreg_output: string): number?
	local ns = string.match(ioreg_output, '"HIDIdleTime"%s*=%s*(%d+)')
	if ns == nil then
		return nil
	end
	return (tonumber(ns) :: number) / 1e9
end

return M
