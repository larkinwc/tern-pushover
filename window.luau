--!strict
-- The window half: watches agents and long commands and sends Pushover notifications.
-- Every Tern window on the machine runs this; lib/dedupe makes one of them send each push.

local detect = require("./lib/detect")
local pushover = require("./lib/pushover")
local settings_mod = require("./lib/settings")
local format = require("./lib/format")
local dedupe = require("./lib/dedupe")
local idle = require("./lib/idle")
local watchdog = require("./lib/watchdog")

type Settings = settings_mod.Settings
type Credentials = pushover.Credentials
type Message = pushover.Message

-- The phone is where pushes arrive, not where they should come from.
if tern.runtime.os == "ios" then
	return
end

-- Each `cx.agents:list()` costs ~10-20 ms, and one tick over Tern's 50 ms budget disables the plugin's
-- timers, so the poll stays slow (see lib/watchdog).
local POLL_MS = 1000
local STALL_MS = 10 * POLL_MS
local ERROR_TOAST_EVERY_SECS = 300

local detector = detect.new()
local dog = watchdog.new(tern.now(), STALL_MS)
-- Turns that ended since the last poll, by pane: "done" or "failed". The next poll sends them with
-- the agent's final message.
local finished: { [number]: string } = {}
local creds: Credentials? = nil
local last_error_toast = -math.huge
local warned_no_keys = false

-- Settings ------------------------------------------------------------------------------------------

local function settings(): Settings
	local ok, stored = pcall(tern.kv.get, "settings")
	return settings_mod.merge(if ok then stored else nil)
end

local function save(s: Settings)
	tern.kv.set("settings", s)
end

-- Credentials (system keychain) ---------------------------------------------------------------------

local function load_creds(done: ((Credentials?, WindowCx?) -> ())?)
	tern.secrets.get("token"):next(function(token, err, _)
		if err ~= nil then
			tern.log.warn("pushover: reading the app token failed:", err)
		end
		tern.secrets.get("user"):next(function(user, err2, cx)
			if err2 ~= nil then
				tern.log.warn("pushover: reading the user key failed:", err2)
			end
			creds = if token ~= nil and user ~= nil then { token = token, user = user } else nil
			if done ~= nil then
				done(creds, cx)
			end
		end)
	end)
end

-- Sending -------------------------------------------------------------------------------------------

local function report(why: string, cx: WindowCx?)
	tern.log.warn("pushover: push failed:", why)
	local now = os.time()
	if cx ~= nil and now - last_error_toast >= ERROR_TOAST_EVERY_SECS then
		last_error_toast = now
		cx:toast("error", "Pushover: push failed", why)
	end
end

local function post(url: string, body: string, done: (why: string?, cx: WindowCx?) -> ())
	tern.fetch(url, {
		method = "POST",
		headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
		body = body,
		timeout_ms = 15000,
	}, function(r, cx)
		local decoded = nil
		if r.error == nil and r.body ~= "" then
			local ok, value = pcall(tern.json.decode, r.body)
			decoded = if ok then value else nil
		end
		done(pushover.failure(r.status, r.error, decoded), cx)
	end)
end

local function deliver(msg: Message, done: ((why: string?, cx: WindowCx?) -> ())?)
	local c = creds
	if c == nil then
		local why = "No Pushover keys yet: run “Pushover: Set up” from the palette."
		if done ~= nil then
			done(why, nil)
		elseif not warned_no_keys then
			warned_no_keys = true
			tern.log.warn("pushover:", why)
		end
		return
	end
	post(pushover.MESSAGES_URL, pushover.body(c, msg), function(why, cx)
		if done ~= nil then
			done(why, cx)
		elseif why ~= nil then
			report(why, cx)
		end
	end)
end

-- Runs `fn` when the "when" setting allows a push now.
local function when_allowed(s: Settings, fn: () -> ())
	if s.when == "always" or tern.runtime.os ~= "macos" then
		fn()
		return
	end
	tern.process.run(idle.ARGV, { timeout_ms = 2000 }, function(result, _)
		local secs = idle.parse(result.stdout)
		-- Unknown idle time: push rather than lose it.
		if secs == nil or secs >= s.away_secs then
			fn()
		end
	end)
end

-- The first window to claim `key` sends it; the others drop it.
local function claim(key: string): boolean
	local ok, recent = pcall(tern.kv.get, "recent")
	local kept, mine = dedupe.claim(if ok then recent else nil, key, os.time())
	if mine then
		pcall(tern.kv.set, "recent", kept)
	end
	return mine
end

local function notify(key: string, msg: Message, s: Settings)
	if s.paused or not claim(key) then
		return
	end
	when_allowed(s, function()
		deliver(msg)
	end)
end

-- Agents --------------------------------------------------------------------------------------------

local function send_finished(pane: number, result: string, s: Settings)
	local agent = detect.agent(detector, pane)
	if agent ~= nil and agent.state == "waiting_input" then
		-- The turn ended on a question: the "needs you" push covers it.
		return
	end
	local title, message = format.agent(result, agent)
	notify(`agent:{pane}:{result}`, { title = title, message = message }, s)
end

local function poll(cx: WindowCx)
	watchdog.ticked(dog, tern.now())
	local ok, agents = pcall(function()
		return cx.agents:list()
	end)
	if not ok then
		return
	end
	-- AgentBlock's fields are a superset of detect.Agent's.
	local waiting = detect.step(detector, (agents :: any) :: { detect.Agent })
	if #waiting == 0 and next(finished) == nil then
		return
	end
	local s = settings()
	if s.needs_you then
		for _, agent in waiting do
			local title, message = format.agent("needs_you", agent)
			notify(
				`agent:{agent.pane}:needs_you`,
				{ title = title, message = message, priority = s.needs_you_priority },
				s
			)
		end
	end
	for pane, result in finished do
		send_finished(pane, result, s)
	end
	table.clear(finished)
end

-- Re-arm first so one failing poll can't stop the loop.
local function timer_loop(cx: WindowCx?)
	if dog.driver ~= "timer" then
		return
	end
	tern.timer(POLL_MS, timer_loop)
	if cx ~= nil then
		poll(cx)
	end
end

local function sleep_loop()
	tern.sleep(POLL_MS):next(function(_, _, cx)
		if dog.driver ~= "sleep" then
			return
		end
		sleep_loop()
		if cx ~= nil then
			poll(cx)
		end
	end)
end

-- Called from other hooks: restarts a stalled poll, or says so once when it can't.
local function check_poll(cx: WindowCx)
	local action = watchdog.check(dog, tern.now())
	if action == "sleep" then
		tern.log.warn("pushover: the agent poll stalled; restarting it")
		sleep_loop()
	elseif action == "dead" then
		tern.log.warn("pushover: the agent poll stalled twice; needs-you pushes are off until plugins reload")
		cx:toast(
			"error",
			"Pushover: needs-you pushes stopped",
			"Tern stopped the plugin's agent check. Run “Reload plugins” to restart it."
		)
	end
	if action == "dead" then
		local s = settings()
		for pane, result in finished do
			send_finished(pane, result, s)
		end
		table.clear(finished)
	end
end

tern.on("agent_finished", function(ev: AgentFinishedEvent, cx: WindowCx)
	if ev.result ~= "done" and ev.result ~= "failed" then
		return
	end
	local s = settings()
	if not s.done then
		return
	end
	if dog.driver == "dead" then
		send_finished(ev.pane, ev.result, s)
	else
		finished[ev.pane] = ev.result
	end
	check_poll(cx)
end)

for _, name in { "title", "focus", "cwd", "command_started", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev: any, cx: WindowCx)
		check_poll(cx)
	end)
end

-- Long commands -------------------------------------------------------------------------------------

tern.on("command_finished", function(ev: CommandFinishedEvent, cx: WindowCx)
	check_poll(cx)
	local s = settings()
	if not s.commands or ev.took_ms < s.command_min_secs * 1000 then
		return
	end
	if detect.agent(detector, ev.pane) ~= nil then
		-- The agent's own program ending; agent pushes cover it.
		return
	end
	local title, message = format.command(ev.line, ev.status, ev.took_ms)
	notify(`cmd:{ev.pane}:{ev.took_ms}`, { title = title, message = message }, s)
end)

-- Palette commands ----------------------------------------------------------------------------------

local function send_test(cx: WindowCx)
	deliver({ title = "Tern", message = "Test notification from the Pushover plugin." }, function(why, fresh)
		local target = fresh or cx
		if why == nil then
			target:toast("success", "Pushover: test sent", "Check your phone.")
		else
			target:toast("error", "Pushover: test failed", why)
		end
	end)
end

local function ask_key(cx: WindowCx, placeholder: string, done: (string?, WindowCx) -> ())
	cx:prompt({ placeholder = placeholder, icon = "key", action = "next" }):next(function(value, _, fresh)
		local target = fresh or cx
		if value == nil then
			done(nil, target)
			return
		end
		local key = string.match(value, "^%s*(.-)%s*$") :: string
		if not pushover.looks_like_key(key) then
			target:toast("error", "Pushover: that isn't a Pushover key", "Keys are 30 letters and digits.")
			done(nil, target)
			return
		end
		done(key, target)
	end)
end

tern.command({
	id = "setup",
	title = "Pushover: Set up",
	icon = "key",
	run = function(cx)
		ask_key(cx, "Pushover application API token (pushover.net/apps/build)", function(token, cx2)
			if token == nil then
				return
			end
			ask_key(cx2, "Pushover user key (top of pushover.net once signed in)", function(user, cx3)
				if user == nil then
					return
				end
				local candidate = { token = token, user = user }
				post(pushover.VALIDATE_URL, pushover.validate_body(candidate), function(why, fresh)
					local target = fresh or cx3
					if why ~= nil then
						target:toast("error", "Pushover rejected those keys", why)
						return
					end
					tern.secrets.set("token", token):next(function(_, err, _)
						if err ~= nil then
							target:toast("error", "Pushover: saving to the keychain failed", err)
							return
						end
						tern.secrets.set("user", user):next(function(_, err2, cx4)
							local t = cx4 or target
							if err2 ~= nil then
								t:toast("error", "Pushover: saving to the keychain failed", err2)
								return
							end
							creds = candidate
							send_test(t)
						end)
					end)
				end)
			end)
		end)
	end,
})

tern.command({
	id = "test",
	title = "Pushover: Send test notification",
	icon = "bell",
	run = send_test,
})

tern.command({
	id = "pause",
	title = "Pushover: Pause or resume notifications",
	icon = "bell",
	run = function(cx)
		local s = settings()
		s.paused = not s.paused
		save(s)
		cx:toast("info", if s.paused then "Pushover: paused" else "Pushover: resumed")
	end,
})

local function on_off(b: boolean): string
	return if b then "on" else "off"
end

local function ask_seconds(cx: WindowCx, placeholder: string, current: number, apply: (Settings, number) -> ())
	cx:prompt({ value = tostring(current), placeholder = placeholder, icon = "clock" }):next(function(value, _, fresh)
		local target = fresh or cx
		if value == nil then
			return
		end
		local n = tonumber(value)
		if n == nil or n < 0 then
			target:toast("error", "Pushover: enter a number of seconds")
			return
		end
		local s = settings()
		apply(s, n)
		save(s)
		target:toast("success", "Pushover: saved")
	end)
end

tern.command({
	id = "settings",
	title = "Pushover: Settings",
	icon = "settings",
	run = function(cx)
		local s = settings()
		cx:pick({
			placeholder = "Pushover settings",
			icon = "bell",
			action = "change",
			items = {
				{ label = "When an agent needs you", detail = on_off(s.needs_you), current = s.needs_you, id = "needs_you" },
				{ label = "When an agent finishes its turn", detail = on_off(s.done), current = s.done, id = "done" },
				{
					label = "When a long command ends",
					detail = on_off(s.commands),
					current = s.commands,
					id = "commands",
				},
				{ label = "Long command means at least…", detail = `{s.command_min_secs}s`, id = "command_min_secs" },
				{
					label = "Only when I'm away from this Mac",
					detail = if s.when == "away" then `on, after {s.away_secs}s idle` else "off",
					current = s.when == "away",
					id = "when",
				},
				{ label = "Away means idle for…", detail = `{s.away_secs}s`, id = "away_secs" },
				{
					label = "Needs-you pushes bypass quiet hours",
					detail = on_off(s.needs_you_priority == 1),
					current = s.needs_you_priority == 1,
					id = "priority",
				},
				{ label = "Forget my Pushover keys", id = "forget" },
			},
		}):next(function(item, _, fresh)
			local target = fresh or cx
			if item == nil then
				return
			end
			local id = item.id
			if id == "command_min_secs" then
				ask_seconds(target, "Seconds a command must run", s.command_min_secs, function(t, n)
					t.command_min_secs = n
				end)
				return
			elseif id == "away_secs" then
				ask_seconds(target, "Seconds without input before you count as away", s.away_secs, function(t, n)
					t.away_secs = n
				end)
				return
			elseif id == "forget" then
				tern.secrets.set("token", nil):next(function()
					tern.secrets.set("user", nil):next(function(_, _, cx2)
						creds = nil;
						(cx2 or target):toast("info", "Pushover: keys removed from the keychain")
					end)
				end)
				return
			end
			if id == "needs_you" then
				s.needs_you = not s.needs_you
			elseif id == "done" then
				s.done = not s.done
			elseif id == "commands" then
				s.commands = not s.commands
			elseif id == "when" then
				s.when = if s.when == "away" then "always" else "away"
			elseif id == "priority" then
				s.needs_you_priority = if s.needs_you_priority == 1 then 0 else 1
			end
			save(s)
			target:toast("success", "Pushover: " .. item.label, if item.current then "off" else "on")
		end)
	end,
})

-- Start ---------------------------------------------------------------------------------------------

load_creds()
tern.timer(POLL_MS, timer_loop)
