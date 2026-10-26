--!strict
-- The plugin's settings, kept in tern.kv under "settings". Missing or mistyped values fall back to defaults.

export type Settings = {
	-- Master switch.
	paused: boolean,
	-- Push when an agent goes from working to waiting for input.
	needs_you: boolean,
	-- Push when an agent's turn ends.
	done: boolean,
	-- Push when a shell command that ran at least `command_min_secs` ends.
	commands: boolean,
	command_min_secs: number,
	-- "always", or "away": only once this computer has had no keyboard or mouse input for `away_secs`.
	when: string,
	away_secs: number,
	-- Pushover priority for "needs you" pushes (-2..1; 1 bypasses quiet hours).
	needs_you_priority: number,
	-- A link button on every push ("" for none) and its label. `tern://` opens Tern's app.
	link_url: string,
	link_title: string,
}

local M = {}

local DEFAULTS: Settings = {
	paused = false,
	needs_you = true,
	done = true,
	commands = true,
	command_min_secs = 60,
	when = "away",
	away_secs = 60,
	needs_you_priority = 0,
	link_url = "tern://",
	link_title = "Open Tern",
}
M.DEFAULTS = DEFAULTS

local function pick<T>(value: any, fallback: T, valid: ((any) -> boolean)?): T
	if type(value) ~= type(fallback) then
		return fallback
	end
	if valid ~= nil and not valid(value) then
		return fallback
	end
	return value
end

local function nonnegative(n: any): boolean
	return n >= 0 and n == n and n ~= math.huge
end

function M.merge(stored: any): Settings
	local s = if type(stored) == "table" then stored else {}
	local d = DEFAULTS
	return {
		paused = pick(s.paused, d.paused),
		needs_you = pick(s.needs_you, d.needs_you),
		done = pick(s.done, d.done),
		commands = pick(s.commands, d.commands),
		command_min_secs = pick(s.command_min_secs, d.command_min_secs, nonnegative),
		when = pick(s.when, d.when, function(v)
			return v == "always" or v == "away"
		end),
		away_secs = pick(s.away_secs, d.away_secs, nonnegative),
		needs_you_priority = pick(s.needs_you_priority, d.needs_you_priority, function(v)
			return v == math.floor(v) and v >= -2 and v <= 1
		end),
		link_url = pick(s.link_url, d.link_url, function(v)
			return #v <= 512 and string.find(v, "%s") == nil
		end),
		link_title = pick(s.link_title, d.link_title, function(v)
			return v ~= "" and #v <= 100
		end),
	}
end

return M
