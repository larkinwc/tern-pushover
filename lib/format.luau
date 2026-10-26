--!strict
-- Titles and bodies of the pushes.

local M = {}

function M.basename(path: string?): string?
	if path == nil or path == "" then
		return nil
	end
	local trimmed = string.gsub(path, "/+$", "")
	if trimmed == "" then
		return "/"
	end
	return string.match(trimmed, "([^/]+)$")
end

function M.duration(ms: number): string
	local secs = math.floor(ms / 1000)
	if secs < 60 then
		return tostring(secs) .. "s"
	end
	local mins = secs // 60
	if mins < 60 then
		return string.format("%dm%02ds", mins, secs % 60)
	end
	return string.format("%dh%02dm", mins // 60, mins % 60)
end

local function where(cwd: string?): string
	local name = M.basename(cwd)
	return if name ~= nil then " · " .. name else ""
end

-- The agent's last words, else a fallback; `last_message` may be tern.json.null.
local function said(last_message: any, fallback: string): string
	if type(last_message) == "string" then
		local text = string.match(last_message, "^%s*(.-)%s*$") :: string
		if text ~= "" then
			return text
		end
	end
	return fallback
end

export type AgentLike = { cwd: string?, command: string?, last_message: any }

-- `kind` is "needs_you", "done" or "failed"; `agent` is nil when no snapshot has seen the pane.
function M.agent(kind: string, agent: AgentLike?): (string, string)
	local a: AgentLike = agent or { cwd = nil, command = nil, last_message = nil }
	local who = if type(a.command) == "string" and a.command ~= "" then a.command else "The agent"
	if kind == "needs_you" then
		return "⏳ Needs you" .. where(a.cwd), said(a.last_message, who .. " is waiting for your input.")
	elseif kind == "failed" then
		return "✗ Failed" .. where(a.cwd), said(a.last_message, who .. " reported a failure.")
	end
	return "✓ Done" .. where(a.cwd), said(a.last_message, who .. " finished its turn.")
end

function M.command(line: string, status: number, took_ms: number, cwd: string?): (string, string)
	local head = if status == 0 then "✓ Command finished" else string.format("✗ Command failed (exit %d)", status)
	return head .. where(cwd), line .. "\nran " .. M.duration(took_ms)
end

return M
