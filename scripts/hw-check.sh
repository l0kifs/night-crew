#!/bin/bash
# NightCrew hardware check — answers the "Not tested" items in docs/SPEC.md §14 on a real Mac:
#   A  does `pmset sleepnow` sleep the Mac while SleepDisabled is 1?              (lid open)
#   B  lid closed: does SleepDisabled 1 keep it awake, is the built-in display lit, does
#      displaysleepnow turn it off, does macOS sleep on its own after disablesleep 0 (A-08),
#      and does sleepnow work if it does not?                                     (lid closed ~5 min)
#   C  clamshell with an external display: what do the lid and display APIs report? (optional)
# Interactive. Restores your original SleepDisabled value on exit.
# Usage: scripts/hw-check.sh [--dry-run]     (--dry-run: read-only preflight, no sudo, no pmset writes)
set -euo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t nightcrew-hw)"
LOG="$WORK/heartbeat.log"
OUT="$ROOT/stress-test/hw-check-$(date +%Y%m%d-%H%M%S).md"
HB_PID=""; KA_PID=""; ORIG_SD=""

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
ask()  { local a; read -r -p "  $1 " a </dev/tty; printf '%s' "$a"; }
mark() { echo "MARK $1 $(date +%s)" >> "$LOG"; }
at()   { awk -v m="$1" '$1=="MARK" && $2==m {print $3}' "$LOG" | tail -1; }
res()  { printf '%s\n' "$*" >> "$OUT"; }

ioreg_key() { ioreg -r -k AppleClamshellState -d 1 | awk -F'= ' -v k="\"$1\"" 'index($0,k){gsub(/ /,"",$2); print $2}'; }
clam()   { ioreg_key AppleClamshellState; }
sd_raw() { pmset -g | awk '/SleepDisabled/{print $2; f=1} END{if(!f) print "absent"}'; }
sd_now() { [ "$(sd_raw)" = 1 ] && echo 1 || echo 0; }
power()  { pmset -g batt | head -1 | sed "s/.*'\(.*\)'.*/\1/"; }
set_sd() { sudo -n /usr/bin/pmset -a disablesleep "$1"; }
# Power assertions held by processes (other agents' tools, caffeinate, Docker) — they can explain a 'did not sleep'.
assertions() { pmset -g assertions | awk '/Listed by owning process/{f=1;next} /Kernel Assertions|^$/{f=0} f && /pid [0-9]+\(/' | cut -c1-140 | sed 's/^ */    /'; }

# Largest heartbeat gap in [from, to]: "<seconds> <epoch it started>". > 10 s means the Mac slept.
max_gap() {
  awk -v a="$1" -v b="$2" '$1=="HB" && $2>=a && $2<=b { if (p && $2-p>g) {g=$2-p; s=p} p=$2 }
    END { printf "%d %d\n", g+0, s+0 }' "$LOG"
}
# Distinct display states seen in [from, to).
phase_disp() {
  awk -v a="$1" -v b="$2" '$1=="HB" && $2>=a && $2<b { s=$0; sub(/^.*disp=/,"",s); c[s]++ }
    END { for (k in c) printf "    %d× %s\n", c[k], k }' "$LOG"
}
# Sleep/Wake records macOS itself logged in [from, to].
pm_events() {
  local a b; a="$(date -r "$1" '+%Y-%m-%d %H:%M:%S')"; b="$(date -r "$2" '+%Y-%m-%d %H:%M:%S')"
  pmset -g log 2>/dev/null | awk -v a="$a" -v b="$b" \
    '/^[0-9]{4}-[0-9]{2}-[0-9]{2} / && substr($0,1,19)>=a && substr($0,1,19)<=b && $4 ~ /^(Sleep|Wake|DarkWake)$/' \
    | cut -c1-160 | sed 's/^/    /'
}
wait_clam() { # $1 Yes|No, $2 timeout seconds
  local i=0; while [ "$(clam)" != "$1" ]; do sleep 1; i=$((i+1)); [ "$i" -ge "$2" ] && return 1; done; return 0
}
slept() { [ "$1" -gt 10 ]; }
# Wall-clock wait. `sleep N` counts only awake time, so after the Mac wakes it would stall with no output.
wait_until() { while [ "$(date +%s)" -lt "$1" ]; do sleep 1; done; }
# First heartbeat gap > 10 s that starts in [from, to]: "<gap s> <start epoch>", or "0 0".
first_gap() {
  awk -v a="$1" -v b="$2" '$1=="HB" && $2>=a { if (p && p<=b && $2-p>10) { printf "%d %d\n", $2-p, p; f=1; exit } p=$2 }
    END { if (!f) print "0 0" }' "$LOG"
}
# Reason macOS logged for the first Sleep in [from, to], e.g. "Idle Sleep" or "Clamshell Sleep".
sleep_reason() { { pm_events "$1" "$2" | awk '$4=="Sleep"' | grep -o "due to '[^']*'" | head -1 | cut -d"'" -f2; } || true; }

cleanup() {
  if [ -n "$HB_PID" ]; then kill "$HB_PID" 2>/dev/null || true; fi
  if [ "$DRY" = 0 ] && [ -s "$LOG" ] && [ -f "$OUT" ]; then cp "$LOG" "${OUT%.md}.heartbeat.log" 2>/dev/null || true; fi
  rm -rf "$WORK"
  if [ "$DRY" = 0 ] && [ -n "$ORIG_SD" ] && [ "$(sd_now)" != "$ORIG_SD" ]; then
    set_sd "$ORIG_SD" 2>/dev/null || sudo /usr/bin/pmset -a disablesleep "$ORIG_SD"
    note "Restored SleepDisabled = $ORIG_SD."
  fi
  if [ -n "$KA_PID" ]; then kill "$KA_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- preflight (read-only)
say "Preflight"
[ "$(uname -s)" = Darwin ] || { echo "macOS only"; exit 1; }
cat > "$WORK/displays.swift" <<'EOF'
import CoreGraphics
var n: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &ids, &n)
let main = CGMainDisplayID()
print(ids.prefix(Int(n)).map { "\($0):builtin=\(CGDisplayIsBuiltin($0) != 0):asleep=\(CGDisplayIsAsleep($0) != 0):main=\($0 == main)" }.joined(separator: " "))
EOF
swiftc -O -o "$WORK/displays" "$WORK/displays.swift" || { echo "swiftc failed — install the Xcode Command Line Tools"; exit 1; }
ORIG_SD="$(sd_now)"
DISP0="$("$WORK/displays")"
mkdir -p "$(dirname "$OUT")"; : > "$OUT"; : > "$LOG"
res "# NightCrew hardware check — $(date '+%Y-%m-%d %H:%M')"
res ""
res "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m), $(sysctl -n hw.model). Power: $(power)."
res "Original SleepDisabled: $ORIG_SD (pmset -g line: $(sd_raw)). Lid: clamshell=$(clam), causesSleep=$(ioreg_key AppleClamshellCausesSleep)."
res "Displays (id:builtin:asleep:main): $DISP0"
note "macOS $(sw_vers -productVersion), power: $(power), SleepDisabled: $(sd_raw), lid closed: $(clam)"
note "Displays: $DISP0"

( while :; do { echo "HB $(date +%s) clam=$(clam) sd=$(sd_raw) disp=$("$WORK/displays")" >> "$LOG"; } || true; sleep 2; done ) &
HB_PID=$!

if [ "$DRY" = 1 ]; then
  sleep 7; t="$(date +%s)"
  note "Heartbeat sample (max gap s, at): $(max_gap $((t-10)) "$t")"
  note "Power assertions now:"; assertions
  note "Display states in the sample:"; phase_disp $((t-10)) $((t+1))
  note "pmset log Sleep/Wake events in the last 24 h:"; pm_events $((t-86400)) "$t" | tail -3
  note "Dry run: nothing changed. Plan: test A (lid open, ~1 min), test B (lid closed ≥ 5 min, unplug if you can), test C (only with an external display)."
  rm -f "$OUT"; exit 0
fi

say "This script changes SleepDisabled, may put the Mac to sleep, and asks you to close the lid."
note "Close running work you care about. It needs your password once (sudo)."
sudo -v
( while :; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
KA_PID=$!

# ---------------------------------------------------------------- A: sleepnow while SleepDisabled 1
say "Test A — does 'pmset sleepnow' sleep the Mac while SleepDisabled is 1? (lid open)"
note "If the screen goes dark, wait ~10 s, then press a key to wake the Mac."
ask "Press Enter to start."
set_sd 1; sleep 3
A_ASSERT="$(assertions)"; mark A_sent; A_OUT="$(pmset sleepnow 2>&1 || true)"; wait_until $(( $(at A_sent) + 25 )); mark A_end
read -r GAP_A _ <<< "$(max_gap "$(at A_sent)" "$(at A_end)")"
res ""; res "## A — sleepnow while SleepDisabled = 1 (lid open)"
res "pmset output: \`$A_OUT\`. Largest heartbeat gap: ${GAP_A}s → $(slept "$GAP_A" && echo SLEPT || echo 'did NOT sleep')."
pm_events "$(at A_sent)" "$(at A_end)" >> "$OUT" || true
res "Power assertions at the time:"; printf '%s\n' "$A_ASSERT" >> "$OUT"

# ---------------------------------------------------------------- B: lid-closed session
say "Test B — lid closed (about 5 minutes)"
note "Power now: $(power). Unplug the charger first if you can: the spec's case is battery."
note "After you close the lid:  0:00 observe · 0:30 displaysleepnow · 1:00 disablesleep 0 ·"
note "                          1:00–4:00 watch whether macOS sleeps by itself · 4:00 sleepnow if it has not."
note "Keep the lid closed at least 5 minutes (phone timer), then open it and wake the Mac."
ask "Press Enter, then close the lid within 60 s."
set_sd 1
res ""; res "## B — lid closed (power: $(power))"
if ! wait_clam Yes 60; then
  res "Skipped: lid was not closed within 60 s."; note "Lid not closed — skipping test B."
else
  mark B_closed; T0="$(at B_closed)"
  wait_until $((T0 + 30)); mark B_dsn; pmset displaysleepnow || true
  wait_until $((T0 + 60)); mark B_sd0; set_sd 0; B_SD0_RAW="$(sd_raw)"; B_ASSERT="$(assertions)"
  wait_until $((T0 + 240)); mark B_watch_end
  read -r GAP_B GAP_B_AT <<< "$(first_gap "$(at B_sd0)" $((T0 + 240)))"
  if ! slept "$GAP_B" && [ "$(clam)" = Yes ]; then mark B_sleepnow; pmset sleepnow || true; wait_until $(( $(at B_sleepnow) + 30 )); fi
  note "Lid session over. Open the lid if it is still closed."
  wait_clam No 7200 || true; mark B_opened
  EARLY="$(awk -v a="$T0" -v b="$((T0 + 240))" '$1=="HB" && $2>=a && $2<=b && /clam=No/' "$LOG" | wc -l | tr -d ' ')"
  if [ "$EARLY" -gt 0 ]; then res "- WARNING: lid was open in $EARLY heartbeats before 4:00 — the A-08 result below is not valid; re-run test B."; fi
  read -r GAP_1 _ <<< "$(first_gap "$T0" "$(at B_sd0)")"
  res "- SleepDisabled 1 kept the lid-closed Mac awake (A-01): $(slept "$GAP_1" && echo "NO — gap ${GAP_1}s" || echo YES)"
  res "- Display states, lid closed, before displaysleepnow (is the built-in lit? §1):"; phase_disp "$(at B_closed)" "$(at B_dsn)" >> "$OUT"
  res "- Display states after displaysleepnow (AC3):"; phase_disp $(( $(at B_dsn) + 4 )) "$(at B_sd0)" >> "$OUT"
  res "- pmset -g SleepDisabled line after setting 0: \`$B_SD0_RAW\`"
  if slept "$GAP_B"; then
    REASON="$(sleep_reason "$(at B_sd0)" "$(at B_opened)")"
    res "- After disablesleep 0 with the lid closed, macOS slept $(( GAP_B_AT - $(at B_sd0) ))s later, reason '${REASON:-unknown}' (A-08)."
    res "  'Clamshell Sleep' = macOS re-applies lid sleep by itself. Anything else (e.g. 'Idle Sleep') = it only idle-slept, which needs the display off,"
    res "  no idle-sleep assertion and a short idle timer (pmset sleep = $(pmset -g | awk '$1=="sleep"{print $2}') min) → keep sleepnow."
  else
    res "- macOS did NOT sleep within 180 s after disablesleep 0 with the lid closed (A-08) → keep sleepnow."
    res "  (inconclusive if a process below held PreventSystemSleep / PreventUserIdleSystemSleep at the switch)"
    if [ -n "$(at B_sleepnow)" ]; then
      read -r GAP_S _ <<< "$(first_gap "$(at B_sleepnow)" "$(at B_opened)")"
      res "- sleepnow with lid closed after disablesleep 0: $(slept "$GAP_S" && echo WORKED || echo 'did NOT sleep')"
    fi
  fi
  res "- Power assertions at the disablesleep 0 switch:"; printf '%s\n' "$B_ASSERT" >> "$OUT"
  res "- macOS sleep/wake records for the session:"; pm_events "$(at B_closed)" "$(at B_opened)" >> "$OUT" || true
fi

# ---------------------------------------------------------------- C: clamshell with external display
say "Test C — clamshell with an external display (optional)"
res ""; res "## C — clamshell with an external display"
if ! printf '%s' "$("$WORK/displays")" | grep -q 'builtin=false'; then
  res "Skipped: no external display connected."; note "No external display connected — skipping."
else
  ask "Close the lid, keep working on the external display, then press Enter there."
  res "Lid closed: clamshell=$(clam), causesSleep=$(ioreg_key AppleClamshellCausesSleep)"
  res "Displays: $("$WORK/displays")   (spec R-06 expects the external display as main, the built-in absent or asleep)"
  ask "Open the lid and press Enter."
fi

say "Done. Results: $OUT"
cat "$OUT"
