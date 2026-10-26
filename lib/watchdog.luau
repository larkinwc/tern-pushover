--!strict
-- Keeps the agent poll alive. Tern disables every `tern.timer` callback of a plugin, until plugins reload,
-- once one callback runs over its 50 ms budget, and `cx.agents:list()` alone can take 10-20 ms with a
-- spike now and then. Other hooks keep running, so window events check here whether the poll stalled:
-- the first stall moves the poll to `tern.sleep` (the separate `await` hook), a second gives up.

export type Driver = "timer" | "sleep" | "dead"

export type Watchdog = {
	driver: Driver,
	last_tick: number,
	stale_ms: number,
}

local M = {}

function M.new(now: number, stale_ms: number): Watchdog
	return { driver = "timer", last_tick = now, stale_ms = stale_ms }
end

function M.ticked(w: Watchdog, now: number)
	w.last_tick = now
end

-- nil while the poll runs; "sleep" when the caller should restart it on tern.sleep; "dead" once both stalled.
function M.check(w: Watchdog, now: number): Driver?
	if w.driver == "dead" or now - w.last_tick < w.stale_ms then
		return nil
	end
	if w.driver == "timer" then
		w.driver = "sleep"
		w.last_tick = now -- the new loop gets a full grace period
		return "sleep"
	end
	w.driver = "dead"
	return "dead"
end

return M
