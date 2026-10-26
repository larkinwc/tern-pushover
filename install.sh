#!/bin/sh
# Installs the tern-pushover plugin and connects it to your Pushover account.
#
#   curl -fsSL https://raw.githubusercontent.com/larkinwc/tern-pushover/main/install.sh | sh
#
# It asks for your Pushover application token and user key; set PUSHOVER_TOKEN and PUSHOVER_USER
# to skip the questions. Run it again to update the plugin or change the keys.
#
# Only Tern can write its keychain, so after Pushover accepts the keys this script leaves them in
# the plugin's data store; a Tern window moves them to the keychain, deletes that copy, and sends
# a test notification.

set -eu

REPO="github.com/larkinwc/tern-pushover"
ID="pushover"
WAIT_SECS=30

say() { printf '%s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() {
	printf '\033[31merror:\033[0m %s\n' "$*" >&2
	exit 1
}

# -- Prerequisites ----------------------------------------------------------------------------------

command -v curl >/dev/null 2>&1 || die "curl is required."

TERN=$(command -v tern 2>/dev/null || true)
if [ -z "$TERN" ] && [ -x /Applications/Tern.app/Contents/MacOS/tern ]; then
	TERN=/Applications/Tern.app/Contents/MacOS/tern
fi
[ -n "$TERN" ] || die "Can't find Tern's 'tern' command. Install Tern (https://stencil.so/tern) and open it once."

if command -v plutil >/dev/null 2>&1; then
	JSON=plutil
elif command -v python3 >/dev/null 2>&1; then
	JSON=python3
else
	die "Needs plutil (macOS) or python3 to hand the keys to Tern."
fi

PLUGINS=$("$TERN" plugin dir) || die "'tern plugin dir' failed."
DATA="$(dirname "$PLUGINS")/plugin-data/$ID"
KV="$DATA/kv.json"

# -- Plugin -----------------------------------------------------------------------------------------

step "Installing the plugin"
if [ -f "$PLUGINS/$ID.path" ]; then
	say "Using the linked copy at $(cat "$PLUGINS/$ID.path")."
elif [ -d "$PLUGINS/$ID" ]; then
	"$TERN" plugin install "$REPO" --force
else
	"$TERN" plugin install "$REPO"
fi

# -- Keys -------------------------------------------------------------------------------------------

is_key() {
	case $1 in
	*[!A-Za-z0-9]* | '') return 1 ;;
	esac
	[ ${#1} -eq 30 ]
}

# ask VAR "question" "help": reads from the terminal even when this script comes through a pipe.
ask() {
	(: </dev/tty) 2>/dev/null || die "No terminal to ask on; set PUSHOVER_TOKEN and PUSHOVER_USER instead."
	while :; do
		say "$3"
		printf '%s: ' "$2" >/dev/tty
		IFS= read -r answer </dev/tty || die "No answer."
		answer=$(printf '%s' "$answer" | tr -d '[:space:]')
		if is_key "$answer"; then
			eval "$1=\$answer"
			return
		fi
		say "That isn't a Pushover key: they're 30 letters and digits."
	done
}

step "Connecting to Pushover"
TOKEN=${PUSHOVER_TOKEN:-}
USER_KEY=${PUSHOVER_USER:-}
if [ -n "$TOKEN" ]; then
	is_key "$TOKEN" || die "PUSHOVER_TOKEN isn't a Pushover key (30 letters and digits)."
else
	ask TOKEN "Application API token" "Create an application named Tern at https://pushover.net/apps/build and copy its API token."
fi
if [ -n "$USER_KEY" ]; then
	is_key "$USER_KEY" || die "PUSHOVER_USER isn't a Pushover key (30 letters and digits)."
else
	ask USER_KEY "User key" "Your user key is at the top of https://pushover.net once you're signed in."
fi

reply=$(curl -sS --max-time 20 -X POST \
	--data-urlencode "token=$TOKEN" --data-urlencode "user=$USER_KEY" \
	https://api.pushover.net/1/users/validate.json) || die "Couldn't reach Pushover."
case $reply in
*'"status":1'*) say "Pushover accepted the keys." ;;
*)
	why=$(printf '%s' "$reply" | sed -n 's/.*"errors":\["\([^"]*\)".*/\1/p')
	die "Pushover rejected the keys: ${why:-$reply}"
	;;
esac

# -- Hand-off to Tern -------------------------------------------------------------------------------

kv_set_pending() {
	if [ "$JSON" = plutil ]; then
		[ -s "$KV" ] || printf '{}' >"$KV"
		plutil -remove import_result "$KV" >/dev/null 2>&1 || true
		plutil -replace pending_keys -json "{\"token\":\"$TOKEN\",\"user\":\"$USER_KEY\"}" "$KV"
	else
		KV="$KV" TOKEN="$TOKEN" USER_KEY="$USER_KEY" python3 - <<'EOF'
import json, os
path = os.environ["KV"]
try:
    with open(path) as f:
        kv = json.load(f)
except (FileNotFoundError, ValueError):
    kv = {}
kv.pop("import_result", None)
kv["pending_keys"] = {"token": os.environ["TOKEN"], "user": os.environ["USER_KEY"]}
with open(path, "w") as f:
    json.dump(kv, f)
EOF
	fi
}

# kv_get PATH prints a value from kv.json ("a.b" for nested keys), or nothing.
kv_get() {
	[ -s "$KV" ] || return 0
	if [ "$JSON" = plutil ]; then
		plutil -extract "$1" raw "$KV" 2>/dev/null || true
	else
		KV="$KV" KEY="$1" python3 -c '
import json, os
v = json.load(open(os.environ["KV"]))
for k in os.environ["KEY"].split("."):
    v = v.get(k) if isinstance(v, dict) else None
if v is not None:
    print(str(v).lower() if isinstance(v, bool) else v)
' 2>/dev/null || true
	fi
}

step "Handing the keys to Tern"
umask 077
mkdir -p "$DATA"
kv_set_pending
chmod 600 "$KV"

i=0
while [ $i -lt $WAIT_SECS ]; do
	ok=$(kv_get import_result.ok)
	if [ -n "$ok" ]; then
		if [ "$ok" = true ]; then
			say "Saved in the keychain, and a test notification is on its way to your phone."
			step "Done"
			say "Tern now pushes when an agent needs you or finishes, and when a long command ends,"
			say "while you're away from the Mac. Change that with 'Pushover: Settings' in Tern's palette."
			exit 0
		fi
		die "Tern took the keys but the test notification failed: $(kv_get import_result.error)"
	fi
	sleep 1
	i=$((i + 1))
done

say "No Tern window picked the keys up within $WAIT_SECS seconds."
say "Open Tern: the plugin finishes the setup as soon as a window starts, and sends a test notification."
say "Until then the keys wait in $KV (readable only by you)."
exit 1
