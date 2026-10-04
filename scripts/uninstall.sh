#!/bin/bash
# NightCrew uninstaller (SPEC §9). Gives back a SleepDisabled NightCrew owns; a manual one is left as it is.
#   scripts/uninstall.sh [--purge]     --purge also removes the menu settings (defaults domain)
set -euo pipefail

LABEL=dev.l0kifs.nightcrew
WATCHDOG_LABEL=$LABEL.watchdog
APP="$HOME/Applications/NightCrew.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

step() { printf '\n==> %s\n' "$*"; }

step "Stopping NightCrew"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true   # SIGTERM: the app gives back an owned SleepDisabled
launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true    # drop a "Launch at login off" override
# An instance started outside launchd gets the same SIGTERM.
pkill -TERM -u "$UID" -f "$APP/Contents/MacOS/nightcrew" 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -u "$UID" -f "$APP/Contents/MacOS/nightcrew" >/dev/null || break; sleep 1; done

step "Removing the sudo rule and the watchdog (needs your password once)"
sudo /bin/sh -s -- "$HOME" "$WATCHDOG_LABEL" <<'ROOT'
set -u
HOME_DIR=$1 WATCHDOG_LABEL=$2
# Still owned means the app could not give it back: do it here, before the rule disappears.
if [ -e "$HOME_DIR/.nightcrew/owned" ]; then /usr/bin/pmset -a disablesleep 0; fi
/bin/launchctl bootout "system/$WATCHDOG_LABEL" 2>/dev/null || true
/bin/rm -f "/Library/LaunchDaemons/$WATCHDOG_LABEL.plist" /etc/sudoers.d/nightcrew
/bin/rm -rf "/Library/Application Support/NightCrew"
ROOT

step "Removing the app and its files"
rm -f "$AGENT_PLIST"
rm -rf "$APP" "$HOME/.nightcrew"
if [ "$PURGE" = 1 ]; then defaults delete "$LABEL" 2>/dev/null || true; fi

STATE=$(pmset -g | awk '$1 == "SleepDisabled" { print $2 }')
step "Done. SleepDisabled is ${STATE:-0}."
