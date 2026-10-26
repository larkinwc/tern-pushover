--!strict
-- Unit tests for the pure modules. Run from the repository root: `luau tests/run.luau`.

local detect = require("../lib/detect")
local pushover = require("../lib/pushover")
local settings = require("../lib/settings")
local format = require("../lib/format")
local dedupe = require("../lib/dedupe")
local idle = require("../lib/idle")
local watchdog = require("../lib/watchdog")

local failures = 0
local count = 0

local function test(name: string, body: () -> ())
	count += 1
	local ok, err = pcall(body)
	if not ok then
		failures += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, what: string?)
	if actual ~= expected then
		error(`{what or "value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

local function agent(pane: number, state: string, last: any?): detect.Agent
	return { pane = pane, state = state, cwd = "/Users/me/work/app", command = "omp", last_message = last }
end

-- detect ----------------------------------------------------------------------------------------------

test("the first snapshot only seeds, even for an agent already waiting", function()
	local d = detect.new()
	eq(#detect.step(d, { agent(1, "waiting_input") }), 0)
	eq(#detect.step(d, { agent(1, "waiting_input") }), 0)
end)

test("only working -> waiting_input means needs you", function()
	local d = detect.new()
	detect.step(d, { agent(1, "working"), agent(2, "working") })
	local waiting = detect.step(d, { agent(1, "waiting_input"), agent(2, "idle") })
	eq(#waiting, 1)
	eq(waiting[1].pane, 1)
end)

test("a wait that holds fires once, and again after more work", function()
	local d = detect.new()
	detect.step(d, { agent(1, "working") })
	eq(#detect.step(d, { agent(1, "waiting_input") }), 1)
	eq(#detect.step(d, { agent(1, "waiting_input") }), 0)
	detect.step(d, { agent(1, "working") })
	eq(#detect.step(d, { agent(1, "waiting_input") }), 1)
end)

test("waits not preceded by work stay quiet, including agents that appear waiting", function()
	local d = detect.new()
	detect.step(d, { agent(1, "idle") })
	eq(#detect.step(d, { agent(1, "waiting_input"), agent(9, "waiting_input") }), 0)
end)

test("the snapshot keeps each agent's latest state and message, and forgets departed panes", function()
	local d = detect.new()
	detect.step(d, { agent(3, "working", "partial") })
	detect.step(d, { agent(3, "idle", "final answer") })
	local a = detect.agent(d, 3) :: detect.Agent
	eq(a.state, "idle")
	eq(a.last_message, "final answer")
	detect.step(d, {})
	eq(detect.agent(d, 3), nil)
end)

-- pushover --------------------------------------------------------------------------------------------

test("form encoding escapes reserved characters and UTF-8", function()
	eq(pushover.form({ { "message", "a b&c=d+e/f?é" } }), "message=a%20b%26c%3Dd%2Be%2Ff%3F%C3%A9")
	eq(pushover.escape("A-z_0.9~"), "A-z_0.9~")
end)

test("body carries keys, title and message in order and skips priority 0", function()
	local creds = { token = "t", user = "u" }
	eq(pushover.body(creds, { title = "T", message = "M", priority = 0 }), "token=t&user=u&title=T&message=M")
	eq(pushover.body(creds, { title = "T", message = "M", priority = 1 }), "token=t&user=u&title=T&message=M&priority=1")
end)

test("an empty message is sent as a space (Pushover rejects empty)", function()
	eq(pushover.body({ token = "t", user = "u" }, { title = "T", message = "" }), "token=t&user=u&title=T&message=%20")
end)

test("truncate counts characters, not bytes, and never splits one", function()
	eq(pushover.truncate("ééé", 3), "ééé")
	local cut = pushover.truncate("éééé", 3)
	eq(cut, "éé…")
	eq(utf8.len(cut), 3)
	eq(utf8.len(pushover.truncate(string.rep("⏳", 2000), 1024)), 1024)
end)

test("keys are 30 letters and digits", function()
	eq(pushover.looks_like_key(string.rep("a", 30)), true)
	eq(pushover.looks_like_key(string.rep("a", 29)), false)
	eq(pushover.looks_like_key(string.rep("a", 29) .. "-"), false)
end)

test("failure: success, API errors, HTTP status and transport errors", function()
	eq(pushover.failure(200, nil, { status = 1 }), nil)
	eq(
		pushover.failure(400, nil, { status = 0, errors = { "application token is invalid", "user key is invalid" } }),
		"application token is invalid; user key is invalid"
	)
	eq(pushover.failure(500, nil, nil), "HTTP 500")
	eq(pushover.failure(0, "connection refused", nil), "connection refused")
	eq(pushover.failure(200, nil, { status = 0, errors = { "nope" } }), "nope")
end)

-- settings --------------------------------------------------------------------------------------------

test("settings fall back per field on missing or invalid values", function()
	local s = settings.merge({
		done = false,
		when = "sometimes",
		away_secs = -5,
		command_min_secs = 0 / 0,
		needs_you_priority = 2,
		commands = "yes",
	})
	eq(s.done, false)
	eq(s.when, "away")
	eq(s.away_secs, 60)
	eq(s.command_min_secs, 60)
	eq(s.needs_you_priority, 0)
	eq(s.commands, true)
	eq(settings.merge(nil).needs_you, true)
	eq(settings.merge({ when = "always", needs_you_priority = 1 }).when, "always")
end)

-- format ----------------------------------------------------------------------------------------------

test("agent pushes name the project and quote the agent", function()
	local title, message = format.agent("needs_you", agent(1, "waiting_input", "  Which branch?\n"))
	eq(title, "⏳ Needs you · app")
	eq(message, "Which branch?")
end)

test("agent pushes fall back when there is no last message", function()
	local null = newproxy() -- stands in for tern.json.null
	local _, message = format.agent("done", { cwd = "", command = nil, last_message = null })
	eq(message, "The agent finished its turn.")
	local title = format.agent("done", { cwd = "/", command = "omp", last_message = "" })
	eq(title, "✓ Done · /")
end)

test("command pushes show the exit status and duration", function()
	local title, message = format.command("make test", 2, 125000, "/w/proj/")
	eq(title, "✗ Command failed (exit 2) · proj")
	eq(message, "make test\nran 2m05s")
	eq(format.duration(59999), "59s")
	eq(format.duration(3725000), "1h02m")
end)

test("failed turns and unseen panes get their own wording", function()
	local title, message = format.agent("failed", agent(1, "idle", nil))
	eq(title, "✗ Failed · app")
	eq(message, "omp reported a failure.")
	local t2, m2 = format.agent("done", nil)
	eq(t2, "✓ Done")
	eq(m2, "The agent finished its turn.")
end)

-- watchdog --------------------------------------------------------------------------------------------

test("a live poll is left alone", function()
	local w = watchdog.new(0, 100)
	watchdog.ticked(w, 90)
	eq(watchdog.check(w, 150), nil)
	eq(w.driver, "timer")
end)

test("the first stall moves to sleep with a fresh grace period, the second gives up once", function()
	local w = watchdog.new(0, 100)
	eq(watchdog.check(w, 100), "sleep")
	eq(watchdog.check(w, 150), nil) -- grace period from the switch
	watchdog.ticked(w, 180)
	eq(watchdog.check(w, 250), nil)
	eq(watchdog.check(w, 280), "dead")
	eq(watchdog.check(w, 1000), nil)
	eq(w.driver, "dead")
end)

-- dedupe ----------------------------------------------------------------------------------------------

test("the first claim wins until the window passes, and old keys are pruned", function()
	local recent, mine = dedupe.claim(nil, "agent:1:done", 100)
	eq(mine, true)
	recent, mine = dedupe.claim(recent, "agent:1:done", 105)
	eq(mine, false)
	recent, mine = dedupe.claim(recent, "agent:2:done", 105)
	eq(mine, true)
	recent, mine = dedupe.claim(recent, "agent:1:done", 100 + dedupe.WINDOW_SECS)
	eq(mine, true)
	eq(recent["agent:2:done"], 105)
	recent = dedupe.claim(recent, "x", 200)
	eq(recent["agent:2:done"], nil)
end)

test("dedupe tolerates a corrupt stored map", function()
	local _, mine = dedupe.claim({ [1] = "junk", k = "nope" }, "k", 10)
	eq(mine, true)
end)

-- idle ------------------------------------------------------------------------------------------------

test("idle time comes from HIDIdleTime nanoseconds", function()
	eq(idle.parse('    |   "HIDIdleTime" = 2500000000\n'), 2.5)
	eq(idle.parse("nothing here"), nil)
end)

print(`{count - failures}/{count} passed`)
if failures > 0 then
	error(`{failures} test(s) failed`)
end
