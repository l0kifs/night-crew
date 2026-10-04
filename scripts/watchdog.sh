#!/bin/sh
# NightCrew watchdog (SPEC §8). Runs as root from the LaunchDaemon dev.l0kifs.nightcrew.watchdog at boot and
# every 60 s, with the user's home as $1. If NightCrew owns SleepDisabled 1 but its heartbeat is older than 60 s
# (app hung, crashed, booted out, or the Mac rebooted), it sets SleepDisabled back to 0.
# It only tests and stats files under the user's home: it never reads their contents, writes or deletes there,
# so a user-writable input can do no more than the user's own sudoers rule already allows.

HOME_DIR=${1:-}
[ -n "$HOME_DIR" ] || exit 0
OWNED="$HOME_DIR/.nightcrew/owned"
HEARTBEAT="$HOME_DIR/.nightcrew/heartbeat"
STALE_AFTER=60

[ -e "$OWNED" ] || exit 0
/usr/bin/pmset -g | /usr/bin/grep -Eq '^[[:space:]]*SleepDisabled[[:space:]]+1([[:space:]]|$)' || exit 0

NOW=$(/bin/date +%s)
BEAT=$(/usr/bin/stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0)
AGE=$((NOW - BEAT))
[ "$AGE" -gt "$STALE_AFTER" ] || exit 0

if /usr/bin/pmset -a disablesleep 0; then
    /usr/bin/logger -t nightcrew-watchdog "nightcrew watchdog: heartbeat ${AGE}s old: SleepDisabled set back to 0"
else
    /usr/bin/logger -t nightcrew-watchdog "nightcrew watchdog: heartbeat ${AGE}s old: pmset -a disablesleep 0 failed"
fi
