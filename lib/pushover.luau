--!strict
-- Pushover's message API: form encoding, field limits and error text.
-- https://pushover.net/api

local M = {}

M.MESSAGES_URL = "https://api.pushover.net/1/messages.json"
M.VALIDATE_URL = "https://api.pushover.net/1/users/validate.json"

local TITLE_MAX = 250
local MESSAGE_MAX = 1024
local URL_TITLE_MAX = 100

-- Percent-encodes everything but RFC 3986 unreserved characters.
function M.escape(s: string): string
	return (string.gsub(s, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- `fields` is a list of {name, value} pairs, encoded in order.
function M.form(fields: { { string } }): string
	local parts = table.create(#fields)
	for _, pair in fields do
		table.insert(parts, M.escape(pair[1]) .. "=" .. M.escape(pair[2]))
	end
	return table.concat(parts, "&")
end

-- Cuts `s` to at most `max` characters (UTF-8 aware), ending with an ellipsis when cut.
function M.truncate(s: string, max: number): string
	local len = utf8.len(s)
	if len == nil then
		-- Not valid UTF-8: cut bytes, which Pushover still accepts.
		return if #s <= max then s else string.sub(s, 1, max - 1) .. "…"
	end
	if len <= max then
		return s
	end
	local cut = utf8.offset(s, max) :: number
	return string.sub(s, 1, cut - 1) .. "…"
end

export type Credentials = { token: string, user: string }
-- `url`/`url_title`: a link shown as a button under the message ("" or nil for none).
export type Message = { title: string, message: string, priority: number?, url: string?, url_title: string? }

function M.body(creds: Credentials, msg: Message): string
	local text = if msg.message == "" then " " else msg.message
	local fields = {
		{ "token", creds.token },
		{ "user", creds.user },
		{ "title", M.truncate(msg.title, TITLE_MAX) },
		{ "message", M.truncate(text, MESSAGE_MAX) },
	}
	if msg.priority ~= nil and msg.priority ~= 0 then
		table.insert(fields, { "priority", tostring(msg.priority) })
	end
	if msg.url ~= nil and msg.url ~= "" then
		table.insert(fields, { "url", msg.url })
		if msg.url_title ~= nil and msg.url_title ~= "" then
			table.insert(fields, { "url_title", M.truncate(msg.url_title, URL_TITLE_MAX) })
		end
	end
	return M.form(fields)
end

function M.validate_body(creds: Credentials): string
	return M.form({ { "token", creds.token }, { "user", creds.user } })
end

-- Pushover keys are 30 characters of [A-Za-z0-9].
function M.looks_like_key(s: string): boolean
	return string.match(s, "^%w+$") ~= nil and #s == 30
end

-- nil when the request succeeded, else a one-line reason.
-- `decoded` is the JSON response body (or nil when it wasn't JSON).
function M.failure(status: number, transport_error: string?, decoded: any): string?
	if transport_error ~= nil then
		return transport_error
	end
	if type(decoded) == "table" then
		if decoded.status == 1 and status == 200 then
			return nil
		end
		if type(decoded.errors) == "table" and #decoded.errors > 0 then
			local errors = {}
			for _, e in decoded.errors do
				table.insert(errors, tostring(e))
			end
			return table.concat(errors, "; ")
		end
	end
	if status == 200 then
		return nil
	end
	return "HTTP " .. tostring(status)
end

return M
