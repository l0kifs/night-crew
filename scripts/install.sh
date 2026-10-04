#!/bin/bash
# NightCrew installer (SPEC §9). Idempotent: re-running updates in place.
#   curl -fsSL https://raw.githubusercontent.com/l0kifs/nightcrew/main/scripts/install.sh | bash
#   scripts/install.sh [--dry-run]     --dry-run: checks, build and validation only; changes nothing
set -euo pipefail

LABEL=dev.l0kifs.nightcrew
WATCHDOG_LABEL=$LABEL.watchdog
REPO=https://github.com/l0kifs/nightcrew.git
USER_NAME=$(id -un)
APP="$HOME/Applications/NightCrew.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUPPORT="/Library/Application Support/NightCrew"
DAEMON_PLIST="/Library/LaunchDaemons/$WATCHDOG_LABEL.plist"
SUDOERS=/etc/sudoers.d/nightcrew
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }
# launchctl bootstrap returns errno 5 transiently on macOS 26+: retry, then confirm with print (SPEC §9 step 7).
bootstrap() {
    local domain=$1 plist=$2 label=$3 attempt
    for attempt in 1 2 3; do
        launchctl bootstrap "$domain" "$plist" 2>/dev/null && break
        [ "$attempt" = 3 ] || sleep 1
    done
    launchctl print "$domain/$label" >/dev/null 2>&1 || die "launchd did not load $label"
}

# 1. Requirements -------------------------------------------------------------------------------------------
step "Checking requirements"
[ "$(uname -s)" = Darwin ] || die "NightCrew runs on macOS only"
OS=$(sw_vers -productVersion)
version_ge "$OS" 13.5 || die "macOS 13.5 or later is required (this Mac: $OS)"
id -Gn | tr ' ' '\n' | grep -qx admin || die "an administrator account is required: installing the sudo rule needs admin rights"
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "the Xcode Command Line Tools are missing. Finish the installer that just opened, then run this again"
fi
SWIFT=$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)
{ [ -n "$SWIFT" ] && version_ge "$SWIFT" 5.9; } || die "Swift 5.9 or later is required (found: ${SWIFT:-none})"
echo "macOS $OS · Swift $SWIFT · admin account $USER_NAME"

# 2. Source -------------------------------------------------------------------------------------------------
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../Package.swift" ]; then
    SRC=$(cd "$SCRIPT_DIR/.." && pwd)
    step "Using the checkout at $SRC"
else
    SRC="$HOME/.nightcrew/src"
    step "Fetching the source into $SRC"
    if [ -d "$SRC/.git" ]; then git -C "$SRC" pull --ff-only; else mkdir -p "$(dirname "$SRC")"; git clone --depth 1 "$REPO" "$SRC"; fi
fi

# 3. Build --------------------------------------------------------------------------------------------------
step "Building NightCrew.app (swift build -c release)"
BUILT_APP=$("$SRC/scripts/bundle.sh" | tail -1)
[ -x "$BUILT_APP/Contents/MacOS/nightcrew" ] || die "the build did not produce $BUILT_APP"

# Everything that will be written to launchd or as root is generated and validated before anything changes.
STAGE=$(mktemp -d -t nightcrew-install)
trap 'rm -rf "$STAGE"' EXIT

cat > "$STAGE/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/nightcrew</string><string>--launchd</string></array>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>LimitLoadToSessionType</key><string>Aqua</string>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
plutil -lint -s "$STAGE/agent.plist" || die "the generated LaunchAgent plist is invalid"

# Runs as root via one sudo. It builds the sudoers rule and the daemon plist itself from its arguments, so no
# user-writable staged file can be swapped in between validation and installation.
cat > "$STAGE/root.sh" <<'ROOT'
set -eu
USER_NAME=$1 HOME_DIR=$2 WATCHDOG_SOURCE=$3 SUPPORT=$4 DAEMON_PLIST=$5 SUDOERS=$6 WATCHDOG_LABEL=$7

RULE=$(/usr/bin/mktemp /tmp/nightcrew-sudoers.XXXXXX)
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$USER_NAME" > "$RULE"
/bin/chmod 0440 "$RULE"
if ! /usr/sbin/visudo -cf "$RULE" >/dev/null; then /bin/rm -f "$RULE"; echo "the sudoers rule did not validate" >&2; exit 1; fi
/usr/bin/install -m 0440 -o root -g wheel "$RULE" "$SUDOERS"
/bin/rm -f "$RULE"

/bin/launchctl bootout "system/$WATCHDOG_LABEL" 2>/dev/null || true
/bin/mkdir -p "$SUPPORT"
/usr/sbin/chown root:wheel "$SUPPORT"
/bin/chmod 0755 "$SUPPORT"
/usr/bin/install -m 0755 -o root -g wheel "$WATCHDOG_SOURCE" "$SUPPORT/watchdog.sh"
/bin/cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$WATCHDOG_LABEL</string>
	<key>ProgramArguments</key><array><string>/bin/sh</string><string>$SUPPORT/watchdog.sh</string><string>$HOME_DIR</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>60</integer>
</dict>
</plist>
EOF
/usr/sbin/chown root:wheel "$DAEMON_PLIST"
/bin/chmod 0644 "$DAEMON_PLIST"
/usr/bin/plutil -lint -s "$DAEMON_PLIST"
for attempt in 1 2 3; do
    /bin/launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null && break
    [ "$attempt" = 3 ] || /bin/sleep 1
done
/bin/launchctl print "system/$WATCHDOG_LABEL" >/dev/null 2>&1 || { echo "launchd did not load $WATCHDOG_LABEL" >&2; exit 1; }
ROOT
sh -n "$STAGE/root.sh" || die "the generated root script has a syntax error"
ROOT_ARGS=("$USER_NAME" "$HOME" "$SRC/scripts/watchdog.sh" "$SUPPORT" "$DAEMON_PLIST" "$SUDOERS" "$WATCHDOG_LABEL")

# The same rule the root script will write, validated now as the user so a bad username fails before any sudo.
printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n' "$USER_NAME" > "$STAGE/sudoers"
/usr/sbin/visudo -cf "$STAGE/sudoers" >/dev/null || die "the sudoers rule for '$USER_NAME' does not validate"

if [ "$DRY_RUN" = 1 ]; then
    step "Dry run: nothing was changed. Validated:"
    echo "  app:        $BUILT_APP → would copy to $APP"
    echo "  agent:      $AGENT_PLIST (plutil OK)"
    echo "  sudoers:    $SUDOERS: $(cat "$STAGE/sudoers")"
    echo "  watchdog:   $SUPPORT/watchdog.sh, $DAEMON_PLIST"
    echo "  root step:  sudo /bin/sh -s -- ${ROOT_ARGS[*]} (sh -n OK)"
    exit 0
fi

# 4. App ----------------------------------------------------------------------------------------------------
step "Installing $APP"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true   # stops the app without a KeepAlive restart; it gives sleep back
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$BUILT_APP" "$APP"

# 5. Root steps (one sudo prompt) ---------------------------------------------------------------------------
step "Installing the sudo rule and the watchdog (needs your password once)"
cat <<EOF
NightCrew keeps the Mac awake with 'pmset -a disablesleep', which needs root. This adds:
  $SUDOERS        lets $USER_NAME run exactly 'pmset -a disablesleep 0' and '... 1' without a password
  $DAEMON_PLIST   a root watchdog that sets SleepDisabled back to 0 if NightCrew dies while holding it
EOF
sudo /bin/sh -s -- "${ROOT_ARGS[@]}" < "$STAGE/root.sh"

# 6–7. LaunchAgent --------------------------------------------------------------------------------------------
step "Starting NightCrew"
mkdir -p "$(dirname "$AGENT_PLIST")"
cp "$STAGE/agent.plist" "$AGENT_PLIST"
if launchctl print-disabled "gui/$UID" | grep -Eq "\"$LABEL\" => (disabled|true)"; then
    echo "Launch at login is off: NightCrew was not started. Turn it on from the menu after opening $APP."
else
    bootstrap "gui/$UID" "$AGENT_PLIST" "$LABEL"
fi

# 8. A manual SleepDisabled stays the user's -----------------------------------------------------------------
if pmset -g | grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1' && [ ! -e "$HOME/.nightcrew/owned" ]; then
    echo "Note: SleepDisabled is 1 and was set by hand. NightCrew leaves it alone (Unmanaged) until you run"
    echo "      sudo pmset -a disablesleep 0"
fi
step "Done. Look for the moon in the menu bar."
