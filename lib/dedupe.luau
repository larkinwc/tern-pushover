--!strict
-- Every Tern window runs the window half and sees every agent, so each would push the same event.
-- Windows share tern.kv; the first to claim an event's key within `WINDOW_SECS` sends it.

local M = {}

M.WINDOW_SECS = 10

-- `recent` maps keys to the os.time() they were claimed. Returns the updated map and whether `key` is ours.
function M.claim(recent: any, key: string, now: number): ({ [string]: number }, boolean)
	local kept: { [string]: number } = {}
	if type(recent) == "table" then
		for k, at in recent do
			if type(k) == "string" and type(at) == "number" and now - at < M.WINDOW_SECS then
				kept[k] = at
			end
		end
	end
	if kept[key] ~= nil then
		return kept, false
	end
	kept[key] = now
	return kept, true
end

return M
