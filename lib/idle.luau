--!strict
-- How long this computer has had no keyboard or mouse input.
-- macOS: `ioreg -c IOHIDSystem` (HIDIdleTime, nanoseconds).
-- Windows: user32's GetLastInputInfo through PowerShell (milliseconds). The script goes in as
-- -EncodedCommand (base64 of UTF-16LE) so no quoting survives Windows' command-line parsing:
--   Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices;
--   public static class TernIdle { [StructLayout(LayoutKind.Sequential)] struct L { public uint cb;
--   public uint t; } [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref L l);
--   public static uint Ms() { L l = new L(); l.cb = 8; GetLastInputInfo(ref l);
--   return unchecked((uint)Environment.TickCount - l.t); } }'; [TernIdle]::Ms()
-- Elsewhere (Linux has no one way to ask) there's no command, and callers treat you as away.

local M = {}

local WINDOWS_SCRIPT = "QQBkAGQALQBUAHkAcABlACAALQBUAHkAcABlAEQAZQBmAGkAbgBpAHQAaQBvAG4AIAAnAHUAcwBpAG4AZwAgAFMAeQBzAHQAZQBtADsAIAB1AHMAaQBuAGcAIABTAHkAcwB0AGUAbQAuAFIAdQBuAHQAaQBtAGUALgBJAG4AdABlAHIAbwBwAFMAZQByAHYAaQBjAGUAcwA7ACAAcAB1AGIAbABpAGMAIABzAHQAYQB0AGkAYwAgAGMAbABhAHMAcwAgAFQAZQByAG4ASQBkAGwAZQAgAHsAIABbAFMAdAByAHUAYwB0AEwAYQB5AG8AdQB0ACgATABhAHkAbwB1AHQASwBpAG4AZAAuAFMAZQBxAHUAZQBuAHQAaQBhAGwAKQBdACAAcwB0AHIAdQBjAHQAIABMACAAewAgAHAAdQBiAGwAaQBjACAAdQBpAG4AdAAgAGMAYgA7ACAAcAB1AGIAbABpAGMAIAB1AGkAbgB0ACAAdAA7ACAAfQAgAFsARABsAGwASQBtAHAAbwByAHQAKAAiAHUAcwBlAHIAMwAyAC4AZABsAGwAIgApAF0AIABzAHQAYQB0AGkAYwAgAGUAeAB0AGUAcgBuACAAYgBvAG8AbAAgAEcAZQB0AEwAYQBzAHQASQBuAHAAdQB0AEkAbgBmAG8AKAByAGUAZgAgAEwAIABsACkAOwAgAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIAB1AGkAbgB0ACAATQBzACgAKQAgAHsAIABMACAAbAAgAD0AIABuAGUAdwAgAEwAKAApADsAIABsAC4AYwBiACAAPQAgADgAOwAgAEcAZQB0AEwAYQBzAHQASQBuAHAAdQB0AEkAbgBmAG8AKAByAGUAZgAgAGwAKQA7ACAAcgBlAHQAdQByAG4AIAB1AG4AYwBoAGUAYwBrAGUAZAAoACgAdQBpAG4AdAApAEUAbgB2AGkAcgBvAG4AbQBlAG4AdAAuAFQAaQBjAGsAQwBvAHUAbgB0ACAALQAgAGwALgB0ACkAOwAgAH0AIAB9ACcAOwAgAFsAVABlAHIAbgBJAGQAbABlAF0AOgA6AE0AcwAoACkA"

local COMMANDS: { [string]: { string } } = {
	macos = { "/usr/sbin/ioreg", "-c", "IOHIDSystem", "-d", "4" },
	windows = {
		"powershell.exe",
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy",
		"Bypass",
		"-EncodedCommand",
		WINDOWS_SCRIPT,
	},
}

-- The command that reports idle time on `os` (tern.runtime.os), or nil when there's none.
function M.command(os: string): { string }?
	return COMMANDS[os]
end

-- Seconds since the last input from that command's output, or nil when it says nothing usable.
function M.parse(os: string, output: string): number?
	if os == "macos" then
		local ns = string.match(output, '"HIDIdleTime"%s*=%s*(%d+)')
		return if ns ~= nil then (tonumber(ns) :: number) / 1e9 else nil
	elseif os == "windows" then
		local ms = string.match(output, "^%s*(%d+)%s*$")
		return if ms ~= nil then (tonumber(ms) :: number) / 1000 else nil
	end
	return nil
end

return M
