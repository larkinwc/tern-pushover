--!strict
-- Wiring tests: runs the real window.luau against a fake `tern` with a controllable clock, where the
-- test decides when Tern's timer and await hooks run (or have been disabled for running over budget).
-- Run from the repository root: `lune run tests/window.luau` (brew install lune).
-- An optional argument loads another copy of window.luau, e.g. an older revision.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local LIBS = {
	["./lib/detect"] = require("../lib/detect"),
	["./lib/pushover"] = require("../lib/pushover"),
	["./lib/settings"] = require("../lib/settings"),
	["./lib/format"] = require("../lib/format"),
	["./lib/dedupe"] = require("../lib/dedupe"),
	["./lib/idle"] = require("../lib/idle"),
	["./lib/watchdog"] = require("../lib/watchdog"),
}

local SOURCE = fs.readFile(process.args[1] or "window.luau")

type Scheduled = { due: number, fn: (any) -> (), hook: "timer" | "await" }

type Options = { secrets: { [string]: string }?, kv: { [string]: any }?, push_fails: string? }

local function harness(opts: Options?)
	local o: Options = opts or {}
	local h = {
		clock = 0,
		queue = {} :: { Scheduled },
		disabled = { timer = false, await = false },
		handlers = {} :: { [string]: (any, any) -> () },
		pushes = {} :: { { [string]: string } },
		kv = o.kv or {},
		secrets = o.secrets or { token = string.rep("t", 30), user = string.rep("u", 30) },
		agents = {} :: { any },
		toasts = {} :: { string },
	}
	local cx = {
		agents = {
			list = function(_)
				return h.agents
			end,
		},
		toast = function(_, _, text)
			table.insert(h.toasts, text)
		end,
	}
	local function schedule(ms: number, hook: "timer" | "await", fn: (any) -> ())
		table.insert(h.queue, { due = h.clock + ms, fn = fn, hook = hook })
	end
	local function resolved(value: any)
		return {
			next = function(_, fn)
				fn(value, nil, cx)
			end,
		}
	end
	local function form_decode(body: string): { [string]: string }
		local out = {}
		for k, v in string.gmatch(body, "([^&=]+)=([^&]*)") do
			out[k] = (string.gsub(v, "%%(%x%x)", function(hex)
				return string.char(tonumber(hex, 16) :: number)
			end))
		end
		return out
	end
	local fake = {
		runtime = { os = "macos", jit = false },
		now = function()
			return h.clock
		end,
		timer = function(ms: number, fn)
			schedule(ms, "timer", fn)
			return {}
		end,
		sleep = function(ms: number)
			return {
				next = function(_, fn)
					schedule(ms, "await", function(c)
						fn(nil, nil, c)
					end)
				end,
			}
		end,
		on = function(name: string, fn)
			h.handlers[name] = fn
		end,
		command = function() end,
		log = { debug = function() end, info = function() end, warn = function() end, error = function() end },
		kv = {
			get = function(key: string)
				return h.kv[key]
			end,
			set = function(key: string, value: any)
				h.kv[key] = value
			end,
		},
		secrets = {
			get = function(name: string)
				return resolved(h.secrets[name])
			end,
			set = function(name: string, value: string?)
				h.secrets[name] = value :: any
				return resolved(nil)
			end,
		},
		json = {
			decode = function(text: string)
				return serde.decode("json", text)
			end,
		},
		process = {
			run = function(_argv, _opts, cb)
				-- An hour without input: away.
				cb({ status = 0, stdout = '"HIDIdleTime" = 3600000000000', stderr = "", timed_out = false }, cx)
			end,
		},
		fetch = function(_url: string, req, cb)
			table.insert(h.pushes, form_decode(req.body))
			if o.push_fails ~= nil then
				local body = serde.encode("json", { status = 0, errors = { o.push_fails } })
				cb({ status = 400, headers = {}, body = body, timed_out = false }, cx)
			else
				cb({ status = 200, headers = {}, body = '{"status":1}', timed_out = false }, cx)
			end
		end,
	}

	local entry = luau.load(SOURCE, {
		debugName = "window.luau",
		environment = {
			tern = fake,
			require = function(path: string)
				return assert(LIBS[path], "unexpected require " .. path)
			end,
		},
	})
	entry()

	-- Moves the clock forward, running what comes due on hooks Tern hasn't disabled.
	function h.advance(ms: number)
		local target = h.clock + ms
		while true do
			table.sort(h.queue, function(a, b)
				return a.due < b.due
			end)
			local first = h.queue[1]
			if first == nil or first.due > target then
				break
			end
			table.remove(h.queue, 1)
			h.clock = first.due
			if not h.disabled[first.hook] then
				first.fn(cx)
			end
		end
		h.clock = target
	end

	function h.event(name: string, payload: any)
		local fn = assert(h.handlers[name], "no handler for " .. name)
		fn(payload, cx)
	end

	function h.agent(state: string, last: string)
		h.agents = { { pane = 7, state = state, cwd = "/work/app", command = "omp", last_message = last } }
	end

	return h
end

local failures, count = 0, 0
local function test(name: string, body: () -> ())
	count += 1
	local ok, err = pcall(body)
	if not ok then
		failures += 1
		print("FAIL " .. name .. ": " .. tostring(err))
	end
end
local function eq(actual: any, expected: any, what: string)
	if actual ~= expected then
		error(`{what}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

test("a finished turn is pushed with the final message by the next poll", function()
	local h = harness()
	h.agent("working", "thinking…")
	h.advance(2000)
	h.event("agent_finished", { pane = 7, result = "done" })
	h.agent("idle", "All tests pass.")
	h.advance(10000)
	eq(#h.pushes, 1, "pushes")
	eq(h.pushes[1].title, "✓ Done · app", "title")
	eq(h.pushes[1].message, "All tests pass.", "message")
end)

test("a finished turn is still pushed when Tern disabled the timers and no other event follows", function()
	local h = harness()
	h.agent("working", "Here is the result.")
	h.advance(2000)
	h.disabled.timer = true -- a poll ran over the 50 ms budget
	h.event("agent_finished", { pane = 7, result = "failed" })
	h.advance(30000)
	eq(#h.pushes, 1, "pushes")
	eq(h.pushes[1].title, "✗ Failed · app", "title")
	eq(h.pushes[1].message, "Here is the result.", "message (last snapshot)")
end)

test("needs-you is pushed by the poll, and a turn ending on that question isn't pushed again", function()
	local h = harness()
	h.agent("working", "")
	h.advance(2000)
	h.agent("waiting_input", "Red or blue?")
	h.event("agent_finished", { pane = 7, result = "done" })
	h.advance(10000)
	eq(#h.pushes, 1, "pushes")
	eq(h.pushes[1].title, "⏳ Needs you · app", "title")
	eq(h.pushes[1].message, "Red or blue?", "message")
end)

test("a stalled timer poll restarts on sleep at the next window event", function()
	local h = harness()
	h.agent("working", "")
	h.advance(2000)
	h.disabled.timer = true
	h.advance(25000) -- past the 20 s stall limit
	h.event("title", { pane = 7, title = "omp" })
	h.agent("waiting_input", "Which branch?")
	h.advance(5000)
	eq(#h.pushes, 1, "pushes")
	eq(h.pushes[1].message, "Which branch?", "message")
end)

local TOKEN, USER = string.rep("a", 30), string.rep("b", 30)

test("installer keys move to the keychain, leave kv, and send a test push", function()
	local h = harness({ secrets = {}, kv = { pending_keys = { token = TOKEN, user = USER } } })
	eq(h.secrets.token, TOKEN, "token in keychain")
	eq(h.secrets.user, USER, "user in keychain")
	eq(h.kv.pending_keys, nil, "plain-text copy")
	eq(#h.pushes, 1, "pushes")
	eq(h.pushes[1].token, TOKEN, "test push token")
	eq(h.pushes[1].user, USER, "test push user")
	eq(h.kv.import_result.ok, true, "import result")
end)

test("keys the installer leaves while Tern runs are picked up by the next poll", function()
	local h = harness({ secrets = {} })
	h.advance(1000)
	h.kv.pending_keys = { token = TOKEN, user = USER }
	h.advance(1000)
	eq(h.secrets.token, TOKEN, "token in keychain")
	eq(h.kv.pending_keys, nil, "plain-text copy")
	eq(h.kv.import_result.ok, true, "import result")
end)

test("a failed test push is reported back to the installer", function()
	local h = harness({
		secrets = {},
		kv = { pending_keys = { token = TOKEN, user = USER } },
		push_fails = "user key is invalid",
	})
	eq(h.kv.pending_keys, nil, "plain-text copy")
	eq(h.kv.import_result.ok, false, "import result")
	eq(h.kv.import_result.error, "user key is invalid", "error")
end)

test("malformed installer keys are dropped, not saved", function()
	local h = harness({ secrets = {}, kv = { pending_keys = { token = "short", user = USER } } })
	eq(h.secrets.token, nil, "token in keychain")
	eq(h.kv.pending_keys, nil, "plain-text copy")
	eq(h.kv.import_result.ok, false, "import result")
	eq(#h.pushes, 0, "pushes")
end)

-- Two windows share one kv store and one keychain, like two Tern windows on the same Mac.
local function long_command(h: any)
	h.event("command_finished", { pane = 3, line = "make test", status = 0, took_ms = 120000 })
end

test("keys set up in one window are used by a window that was already open", function()
	local kv, secrets = {}, {}
	local a = harness({ kv = kv, secrets = secrets })
	local b = harness({ kv = kv, secrets = secrets })
	long_command(b) -- no keys anywhere yet
	eq(#b.pushes, 0, "pushes without keys")
	kv.pending_keys = { token = TOKEN, user = USER }
	a.advance(2000) -- window A imports them
	eq(#a.pushes, 1, "A's test push")
	long_command(b)
	eq(#b.pushes, 1, "B's push with the new keys")
	eq(b.pushes[1].token, TOKEN, "B's token")
	eq(b.pushes[1].user, USER, "B's user")
end)

test("a window without keys doesn't claim an event that a window with keys can send", function()
	local kv, secrets = {}, {}
	local a = harness({ kv = kv, secrets = secrets })
	local b = harness({ kv = kv, secrets = secrets })
	kv.pending_keys = { token = TOKEN, user = USER }
	a.advance(2000)
	secrets.token, secrets.user = nil, nil -- B's stale view: pretend its keychain read fails
	local saved_rev = kv.creds_rev
	kv.creds_rev = saved_rev + 1
	long_command(b) -- B refreshes, finds no keys, and must leave the event alone
	secrets.token, secrets.user = TOKEN, USER
	long_command(a) -- A refreshes too and sends it
	eq(#b.pushes, 0, "B pushes")
	eq(#a.pushes, 2, "A pushes (test + command)")
end)

test("changed keys reach every open window", function()
	local kv, secrets = {}, {}
	local a = harness({ kv = kv, secrets = secrets })
	local b = harness({ kv = kv, secrets = secrets })
	kv.pending_keys = { token = TOKEN, user = USER }
	a.advance(2000)
	long_command(b)
	local NEW_USER = string.rep("c", 30)
	kv.pending_keys = { token = TOKEN, user = NEW_USER }
	kv.recent = nil -- let the same command be sent again
	a.advance(2000)
	long_command(b)
	eq(#b.pushes, 2, "B pushes")
	eq(b.pushes[1].user, USER, "first push")
	eq(b.pushes[2].user, NEW_USER, "after the change")
end)

print(`{count - failures}/{count} passed`)
if failures > 0 then
	process.exit(1)
end
