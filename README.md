# tern-pushover

A [Tern](https://stencil.so/tern) plugin that sends [Pushover](https://pushover.net) notifications to your phone when:

- an agent **needs you** (it went from working to waiting for your input),
- an agent **finishes** its turn, or reports a failure,
- a shell **command that ran a while** ends (60 s by default), with its exit status.

By default it only pushes when you're **away**: the Mac has had no keyboard or mouse input for 60 seconds. At your desk, Tern's own banners do the job.

## Install

You need a Pushover account and its app on your phone. Pushover is a one-time purchase per platform after a 30-day trial.

1. Create an application at [pushover.net/apps/build](https://pushover.net/apps/build) (name it "Tern"; the icon is optional) and copy its **API token**.
2. Copy your **user key** from the top of [pushover.net](https://pushover.net) once signed in.
3. Install the plugin:

   ```sh
   tern plugin install github.com/larkinwc/tern-pushover
   ```

4. In Tern's command palette run **Pushover: Set up** and paste the token, then the user key. Pushover checks the keys, they're saved in the macOS keychain, and a test notification is sent.

## Commands

| Palette command | What it does |
| --- | --- |
| Pushover: Set up | Enter, check and save your keys, then send a test |
| Pushover: Send test notification | Send a test now, ignoring the away and pause settings |
| Pushover: Pause or resume notifications | Stop or restart all pushes |
| Pushover: Settings | Turn each kind of push on or off; set the long-command and away thresholds; let needs-you pushes through quiet hours (Pushover priority 1); forget your keys |

Settings live in the plugin's `kv.json` (in Tern's `plugin-data/pushover`); your keys don't. They're in the system keychain.

## How it works

Everything runs in the plugin's window half, which every Tern window on the Mac runs:

- **Needs you:** checks `cx.agents:list()` once a second and pushes on `working → waiting_input`, the same check [tern-chime](https://github.com/H4vC/tern-chime) uses.
- **Finished:** Tern's `agent_finished` event. The push goes out on the next check so it carries the agent's final message, and is skipped when the turn ended on a question, since the needs-you push covers that.
- **Long commands:** Tern's `command_finished` event. An agent's own program exiting doesn't count.
- **Several windows:** each one sees every event. They share the plugin's kv store, and the first to claim an event sends it.

### Limits

- **A Tern window has to be open on the Mac.** A plugin's window half only runs in windows; the daemon alone doesn't run it. Plugins also can't read the keychain from the daemon side.
- **Tern's 50 ms budget.** If one timer callback runs longer than 50 ms, Tern disables all of the plugin's timers until plugins reload, and listing agents takes 10–20 ms. So the plugin checks once a second rather than four times, and a watchdog on other events restarts a stalled check on `tern.sleep`. If that stalls too, a toast says so; run **Reload plugins** to restart it. Finished and long-command pushes don't depend on the check and keep working.
- **Away detection is macOS only.** On other systems it always pushes.
- **Repeats within 10 seconds** of the same event in the same pane are dropped.

## Development

```sh
tern plugin link .            # use this checkout; saving a file reloads the plugin
tern plugin types .           # writes tern.d.luau for luau-lsp (git-ignored)
luau tests/run.luau           # unit tests for lib/ (brew install luau)
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau window.luau lib/*.luau
```

Logs go to `~/Library/Logs/Tern/tern.log`. Warnings show by default; start Tern with `STENCIL_LOG=warn,stencil=info,tern::plugin=debug` for more.

## License

MIT
