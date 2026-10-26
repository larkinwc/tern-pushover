# tern-pushover

A [Tern](https://stencil.so/tern) plugin that sends [Pushover](https://pushover.net) notifications to your phone when:

- an agent **needs you** (it went from working to waiting for your input),
- an agent **finishes** its turn, or reports a failure,
- a shell **command that ran a while** ends (60 s by default), with its exit status.

By default it only pushes when you're **away**: the Mac has had no keyboard or mouse input for 60 seconds. At your desk, Tern's own banners do the job.

## Install

You need a Pushover account and its app on your phone. Pushover is a one-time purchase per platform after a 30-day trial. Before you start, create an application at [pushover.net/apps/build](https://pushover.net/apps/build) (name it "Tern"; the icon is optional) so you have its **API token**. Your **user key** is at the top of [pushover.net](https://pushover.net).

With Tern open, run:

```sh
curl -fsSL https://raw.githubusercontent.com/larkinwc/tern-pushover/main/install.sh | sh
```

The script:

1. installs the plugin (`tern plugin install github.com/larkinwc/tern-pushover`);
2. asks for the token and user key, and checks them with Pushover;
3. hands them to Tern, which saves them in the keychain and sends a test notification to your phone.

To skip the questions, set `PUSHOVER_TOKEN` and `PUSHOVER_USER` first. Run it again to update the plugin or change the keys.

Only Tern can write its own keychain item, so the script leaves the keys in the plugin's data store (`plugin-data/pushover/kv.json`, readable only by you). The first Tern window to see them moves them to the keychain and deletes that copy, usually within a second. If no Tern window is open, they wait there until one starts.

**By hand:** `tern plugin install github.com/larkinwc/tern-pushover`, then run **Pushover: Set up** in Tern's command palette and paste the token, then the user key.

**Uninstall:** `tern plugin remove pushover`, and **Pushover: Settings → Forget my Pushover keys** first if you want the keys out of the keychain.

## Commands

| Palette command | What it does |
| --- | --- |
| Pushover: Set up | Enter, check and save your keys, then send a test |
| Pushover: Send test notification | Send a test now, ignoring the away and pause settings |
| Pushover: Pause or resume notifications | Stop or restart all pushes |
| Pushover: Settings | Turn each kind of push on or off; set the long-command and away thresholds; let needs-you pushes through quiet hours (Pushover priority 1); set or clear the link on each push and its label; forget your keys |

Settings live in the plugin's `kv.json` (in Tern's `plugin-data/pushover`); your keys don't. They're in the system keychain.

### Getting back to Tern from a push

Tapping a Pushover notification opens the Pushover app; iOS doesn't let it open another app directly. So every push carries an **Open Tern** button with the link `tern://`, which opens Tern's iPhone app: notification → **Open Tern**. Point it elsewhere under **Pushover: Settings → Link on each push…**, for example your Tern web client's address (`tern web serve`), or clear it to drop the button. Tern has no links to a particular session yet, so the button opens the app, not the agent.

## How it works

Everything runs in the plugin's window half, which every Tern window on the Mac runs:

- **Needs you:** checks `cx.agents:list()` every 2 seconds and pushes on `working → waiting_input`, the same check [tern-chime](https://github.com/H4vC/tern-chime) uses.
- **Finished:** Tern's `agent_finished` event. The next check sends it with the agent's final message. If no check runs within 6 seconds (say Tern disabled the timers), a fallback on the separate `tern.sleep` hook sends it with the last message seen. It's skipped when the turn ended on a question, since the needs-you push covers that.
- **Long commands:** Tern's `command_finished` event. An agent's own program exiting doesn't count.
- **Several windows:** each one sees every event. They share the plugin's kv store, and the first to claim an event sends it.

### Limits

- **A Tern window has to be open on the Mac.** A plugin's window half only runs in windows; the daemon alone doesn't run it. Plugins also can't read the keychain from the daemon side.
- **Tern's 50 ms budget.** If one timer callback runs longer than 50 ms, Tern disables all of the plugin's timers until plugins reload. Listing agents takes 10–20 ms, and more while the Mac is busy, so this happens every so often. The plugin checks every 2 seconds to limit the exposure. A watchdog on other window events restarts a stalled check on `tern.sleep`, and if that stalls too, it runs **Reload plugins** itself (at most every 10 minutes; Tern can only reload all plugins at once) or, failing that, shows a toast. Finished and long-command pushes don't need the timers: they arrive on Tern events and have their own fallback.
- **Away detection is macOS only.** On other systems it always pushes.
- **Repeats within 10 seconds** of the same event in the same pane are dropped.

## Development

```sh
tern plugin link .            # use this checkout; saving a file reloads the plugin
tern plugin types .           # writes tern.d.luau for luau-lsp (git-ignored)
luau tests/run.luau           # unit tests for lib/ (brew install luau)
lune run tests/window.luau    # window.luau against a fake tern, incl. disabled timers (brew install lune)
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau window.luau lib/*.luau
```

Logs go to `~/Library/Logs/Tern/tern.log`. Warnings show by default; start Tern with `STENCIL_LOG=warn,stencil=info,tern::plugin=debug` for more.

## License

MIT
