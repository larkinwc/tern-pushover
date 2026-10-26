--!strict
-- Turns successive agent snapshots (`cx.agents:list()`) into "needs you" notifications
-- (working -> waiting_input) and keeps the latest snapshot of each agent for messages.
-- The first snapshot only seeds the states, so agents already waiting when Tern starts stay quiet.
-- Turn ends come from Tern's `agent_finished` event instead (see window.luau).

export type Agent = {
	pane: number,
	state: string,
	cwd: string?,
	command: string?,
	last_message: any,
}

export type Detector = {
	agents: { [number]: Agent },
	seeded: boolean,
}

local M = {}

function M.new(): Detector
	return { agents = {}, seeded = false }
end

-- Returns the agents that just started waiting for input.
function M.step(d: Detector, agents: { Agent }): { Agent }
	local waiting: { Agent } = {}
	local now: { [number]: Agent } = {}
	for _, agent in agents do
		now[agent.pane] = agent
		local prev = d.agents[agent.pane]
		if d.seeded and prev ~= nil and prev.state == "working" and agent.state == "waiting_input" then
			table.insert(waiting, agent)
		end
	end
	d.agents = now
	d.seeded = true
	return waiting
end

-- The agent in `pane` as of the last snapshot.
function M.agent(d: Detector, pane: number): Agent?
	return d.agents[pane]
end

return M
