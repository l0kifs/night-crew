# NightCrew — Implementation Spec

macOS menu bar (tray) utility. Keeps the MacBook awake (including with the lid closed) while AI coding agent sessions (Claude Code, Codex CLI) are working. Turns the display off when the lid is closed. Restores normal sleep when the agents are done.

Repo: `github.com/l0kifs/nightcrew`. Target: macOS 13.5+ (Swift 5.9 ships with the Xcode 15 Command Line Tools, which require macOS 13.5), Apple Silicon (Intel best-effort).

## 1. Problem

- Agents run for hours. With the lid closed the Mac sleeps and the agents stop.
- `sudo pmset -a disablesleep 1` prevents that, but the internal display stays lit with the lid closed, which wastes battery.
- Toggling this by hand is error-prone: it is easy to forget to turn it on, and easy to leave it on afterwards.

## 2. Goals / Non-goals

Goals:
- Detect running Claude Code / Codex sessions automatically and decide whether each one is *working*.
- Enable `disablesleep` automatically while any session is working, and disable it when none are (after a grace period).
- Sleep the built-in display when the lid closes while the app is keeping the Mac awake.
- Install with one command from the GitHub repo. No Apple Developer account required.
- Fail safe: if NightCrew dies, hangs, or runs outside launchd while it owns `SleepDisabled 1`, the setting returns to 0 within 180 s (§8).
- Never keep the Mac awake at thermal state `serious` or worse, or on battery below the floor (§6.2).

Non-goals (v1): Linux/Windows; GUI agent apps (Claude.app, Codex desktop app); notarization; Homebrew; a settings window (the menu is enough).

## 3. Tech stack

- Swift 5.9+, SwiftPM, AppKit `NSStatusItem` (or SwiftUI `MenuBarExtra`), no third-party deps.
- `LSUIElement = true` (no Dock icon).
- Bundle id: `dev.l0kifs.nightcrew`.
- Built locally from source by the install script, then ad-hoc signed (`codesign -s -`). Building locally means there is no quarantine flag and no Gatekeeper issues.

## 4. Repo layout

```
Package.swift
Sources/NightCrewCore/      # pure logic, no side effects — fully unit-tested
  Matcher.swift             # process → agent classification
  ActivityTracker.swift     # transcript + CPU-delta activity per session (§5.3)
  Engine.swift              # state machine, desired-state computation
  Config.swift
Sources/NightCrew/          # app + side effects
  App.swift, MenuController.swift
  ProcessProbe.swift        # libproc / sysctl
  TranscriptProbe.swift     # transcript mtimes (§5.3)
  PowerControl.swift        # pmset, IOKit lid/display/battery/thermal
  Ownership.swift           # crash-safe ownership of SleepDisabled, heartbeat, single instance
Tests/NightCrewCoreTests/
Resources/Info.plist
scripts/install.sh, scripts/uninstall.sh, scripts/bundle.sh, scripts/watchdog.sh
scripts/hw-check.sh         # guided lid-closed hardware check for the §14 "Not tested" items
Makefile                    # build, bundle, install, uninstall, test
README.md
```

Keep side effects behind protocols (`ProcessProbing`, `TranscriptProbing`, `PowerControlling`, `Clock`) so that `Engine` is testable with fakes.

## 5. Session detection

### 5.1 Process enumeration
- `proc_listallpids` → for each pid: `proc_pidpath`, argv via `sysctl(KERN_PROCARGS2)`, ppid via `proc_pidinfo(PROC_PIDTBSDINFO)`, cwd via `PROC_PIDVNODEPATHINFO`.
- Only the current user's processes are relevant. Skip EPERM failures silently.

### 5.2 Matching (defaults; configurable)
A process is a session root when it matches a rule and its parent does not match the same agent, which prevents double counting.

| Agent  | Match (any)                                                                                                  | Exclude                          |
|--------|--------------------------------------------------------------------------------------------------------------|----------------------------------|
| claude | argv[0] basename == `claude`; any arg contains `@anthropic-ai/claude-code`; exe path contains `/.local/share/claude/versions/` or `anthropic.claude-code-` | exe path contains `.app/Contents/` |
| codex  | argv[0] basename == `codex`; any arg contains `@openai/codex`; exe path contains `openai.chatgpt-`              | exe path contains `.app/Contents/` |

Gotchas:
- A native Claude install's binary is named after its version (`…/versions/2.x.y`). Match on argv[0] or the path, never only on `comm`.
- npm installs run as `node …/cli.js`. Match on args.
- The VS Code Codex extension keeps `codex app-server` alive while idle. The activity check (5.3) is what keeps this from producing false positives.
- **Before finalizing the matchers, verify the actual names on the machine**: `ps -axo pid,ppid,comm,args | grep -Ei 'claude|codex'`, for idle and working sessions, CLI and VS Code. (Verified 2026-10-02 for the Claude Code VS Code extension 2.1.286: `~/.vscode/extensions/anthropic.claude-code-2.1.286-darwin-arm64/resources/native-binary/claude`, parent `Code Helper (Plugin)`. Codex not yet verified.)

### 5.3 Activity (working vs idle)
A session is *working* when either signal fired within the last `activityWindow` (default 60 s):

1. **Transcript write** — the agent appended to its session transcript.
   - claude: the newest `*.jsonl` in `~/.claude/projects/<encoded cwd>/`, where the encoded cwd replaces every character other than `A–Z a–z 0–9` with `-` (observed for `/` and `.`: `/Users/x/.foo` → `-Users-x--foo`). Attributed to the session with that cwd.
   - codex: the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Attributed to the agent: every live codex session root is marked working.
   - A transcript counts only while a live session root of that agent (for claude, with that cwd) exists.
   - The transcript roots are watched with FSEvents (latency 0.5 s). A write triggers an immediate poll, so a prompt submitted just before the lid closes reaches `disablesleep 1` before the Mac can sleep.
2. **CPU** — total CPU time of the root process plus all descendants (the subtree built from the ppid map), via `proc_pidinfo(PROC_PIDTASKINFO)`: `pti_total_user + pti_total_system`. Working if the delta over `activityWindow` is at least `cpuThreshold` (default 3.0 s, i.e. 5 % of one core).
   - **Apple Silicon gotcha:** these values are in mach ticks. Convert with `mach_timebase_info`.
   - Descendants count, because tool calls (tests, builds, git) run as children.

Why two signals — measured 2026-10-02 (macOS 27, Claude Code 2.1.286 in VS Code, two independent `ps` samples): idle session 0.25–0.57 s CPU per 60 s; a session between turns with background watchers (`docker compose logs -f`, a Python watch loop) 0.60–0.79 s; working sessions 0.75–1.26 s while the model thinks or streams, 2.2–2.9 s with light tool calls. CPU cannot separate those; transcript writes did (working: written within the last second; idle: 9 minutes old). The CPU signal exists for heavy tool calls (builds, tests), which use one or more full cores and write no transcript until they finish.

- If an agent's transcript root (`~/.claude/projects`, `~/.codex/sessions`) does not exist while it has live sessions, log it once, use CPU only for that agent, and show "Detection degraded" in the menu. A missing per-project folder is normal before a session's first prompt and is not degraded.
- Recalibrate per release by logging CPU deltas and transcript ages for idle and working sessions; document the measured values in the README. AC5 is the gate.
- Known blind spots, covered only by the grace period (6.2): a thinking or API-wait phase longer than `grace`; work that runs outside the session's process tree (Docker Desktop/colima VMs are children of launchd, ssh, remote CI) with no transcript write and little local CPU; background tasks and scheduled wakeups between turns. Workaround: Always awake. Phase 2 hooks (§11) narrow it.
- At every awake true→false, log each session's live descendants other than MCP servers. A non-empty list is the trip-wire for the second blind spot (§14).

## 6. Engine

### 6.1 Inputs, polled every `pollInterval` (default 5 s)
sessions (with working flag), lid closed, external display online, built-in display asleep, on battery + battery %, thermal state, observed `SleepDisabled`, `ownsSleepDisabled`, mode (+ Always awake expiry), app launch time, config, clock.

The poll timer is scheduled in `RunLoop.Mode.common`, so an open menu does not pause polling.

### 6.2 Desired state
Rules are evaluated in order; the first match wins.

```
1. observed SleepDisabled == 1 && !owned   → Unmanaged: no power action of any kind (§6.3)
2. thermalState >= .serious                → awake = false   (any mode)
3. onBattery && floor != off && pct < floor → awake = false  (any mode)
4. mode == .off                            → awake = false
5. mode == .alwaysOn                       → awake = true
6. mode == .auto                           → awake = anyWorking || (now - lastWorkingAt < grace)   // grace default 10 min
```

- Thermal pause (rule 2) ends after the thermal state has been `fair` or better for 10 min continuously. One notification per pause.
- Battery pause (rule 3) ends as soon as the Mac is on AC or above the floor. One notification per discharge; the counter resets on AC.
- Always awake reverts to Auto 8 h after it was selected. The expiry is persisted, so an expired Always awake loads as Auto after a restart.
- `lastWorkingAt` is persisted in UserDefaults (at most every 30 s while a session is working) and restored on launch. A restart therefore neither shortens the grace period (no false `sleepnow` while the first CPU sample has no baseline) nor extends it (a crash loop with no work still reaches awake = false).

### 6.3 Actions
`SleepDisabled` is level-triggered: every poll compares desired `awake` with the observed value and acts only on a mismatch. One-shot commands (`sleepnow`, `displaysleepnow`) are edge-triggered. Each action is logged once per transition, never per poll.

| Condition                                                                 | Action |
|---------------------------------------------------------------------------|--------|
| awake, observed ≠ 1                                                       | create the ownership file (§8) → `setSleepDisabled(true)` → read back. Read-back ≠ 1 or sudo failure → `setSleepDisabled(false)`, clear ownership, error state |
| !awake, owned                                                             | `setSleepDisabled(false)` → read back. Read-back ≠ 1 → clear ownership. Otherwise retry every 60 s, never stopping; log each failure; icon shows error |
| awake true→false because agents finished, lid closed, no external display, `sleepWhenDone` | `pmset sleepnow` |
| awake true→false because of rule 2 or 3, lid closed, no external display  | `pmset sleepnow` (ignores `sleepWhenDone`) |
| lid open→closed, owned and awake, no external display                     | `pmset displaysleepnow` |
| lid closed, owned and awake, no external display, built-in display not asleep | `pmset displaysleepnow` (at most once per 60 s) |
| external display online                                                   | no lid-related action: a lid-closed Mac with an external display is in use |
| Unmanaged (rule 1)                                                        | none |

- "No external display" means `CGGetOnlineDisplayList` returns no display with `CGDisplayIsBuiltin == false`. "Built-in display asleep" is `CGDisplayIsAsleep` on the built-in display's ID, never `CGMainDisplayID` (in clamshell mode that is the external display).
- Measured 2026-10-04 (MacBookPro17,1, macOS 27.0, battery; `scripts/hw-check.sh`): after `disablesleep 0` with the lid closed, macOS does **not** re-apply lid sleep. It went to 'Idle Sleep' 27 s later only because the built-in display was already off, no process held `PreventUserIdleSystemSleep`, and the idle timer was 1 min. With the display lit, powerd holds that assertion ("Prevent sleep while display is on"). So the `sleepnow` rows and the `sleepWhenDone` toggle stay.
- `sleepnow` is refused while `SleepDisabled` is 1 (`Unable to sleep system: error 0xe00002e2`, measured). It is issued only after the read-back shows `SleepDisabled` is not 1.
- `Engine` returns a list of actions, and the app layer executes them. Unit-test the transitions with fake inputs.

## 7. Power control

| Op                  | Implementation                                                                        |
|---------------------|----------------------------------------------------------------------------------------|
| set SleepDisabled   | `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1` / `… 0` (exact argv, see §9)        |
| read SleepDisabled  | parse `pmset -g` for `SleepDisabled\s+(\d)`, every poll. A missing line reads as "not 1" |
| display sleep now   | `/usr/bin/pmset displaysleepnow` (no root). Measured: built-in display asleep within 2 s with the lid closed |
| system sleep now    | `/usr/bin/pmset sleepnow` (no root). Refused while `SleepDisabled` is 1 (§6.3)        |
| lid state           | IORegistry `IOPMrootDomain` → `AppleClamshellState` (Bool)                            |
| external display    | `CGGetOnlineDisplayList` + `CGDisplayIsBuiltin`. Not `AppleClamshellCausesSleep`: it read `No` with no external display (2026-10-04) and `Yes` on 2026-10-02 |
| display asleep      | `CGDisplayIsAsleep(<built-in display ID>)`                                            |
| battery             | `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList`                               |
| thermal state       | `ProcessInfo.processInfo.thermalState` + `thermalStateDidChangeNotification`          |

- `disablesleep` is not documented in `man pmset` (checked on macOS 27). The read-back in §6.3 is what detects it silently stopping working.
- If `sudo -n` fails on the ON path (sudoers entry missing or stale), the menu shows **"Setup required"** with the fix command, and the ON path stops until the user clicks Retry. The OFF path keeps retrying every 60 s.
- Prevent App Nap from throttling the poll timer: set `NSAppSleepDisabled` in Info.plist, or call `ProcessInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep)`.

## 8. Fail-safety and ownership

- Ownership (`ownsSleepDisabled`) is the file `~/.nightcrew/owned`. It is created (write + `fsync`) **before** `disablesleep 1`, and removed only **after** a read-back shows `SleepDisabled` is not 1. It is a plain file, not UserDefaults, because cfprefsd writes are asynchronous and the root watchdog must read it.
- On launch, reconcile:
  - `SleepDisabled == 1` and owned → keep it, with the grace rule in §6.2.
  - `SleepDisabled == 1` and not owned → this is the user's manual setting. Unmanaged (§6.2 rule 1): no pmset call of any kind until it reads 0. The menu shows "Sleep disabled manually (unmanaged)".
  - `SleepDisabled ≠ 1` and owned → clear ownership.
- On Quit, SIGTERM or SIGINT → if owned, set `disablesleep 0`, clear ownership, exit 0.
- **One instance, always under launchd.** The LaunchAgent starts the binary with `--launchd`. Started without it (Finder, `open`), the app runs `launchctl kickstart gui/$UID/dev.l0kifs.nightcrew` and exits 0. If kickstart fails (the job is disabled by "Launch at login" off), it runs in-process and the watchdog covers it. A second instance (`flock` on `~/.nightcrew/lock`) exits 0.
- The LaunchAgent uses `KeepAlive = { SuccessfulExit = false }`, so a crash restarts the app (launchd allows one spawn per 10 s), and the restart runs the reconcile above. Per `man launchd.plist`, this key implies `RunAtLoad`.
- **Watchdog.** Every poll touches `~/.nightcrew/heartbeat`. A LaunchDaemon `dev.l0kifs.nightcrew.watchdog` (root; `RunAtLoad`, `StartInterval = 60`; the user's home path is written into its `ProgramArguments` at install) runs `/Library/Application Support/NightCrew/watchdog.sh` (root:wheel, 0755). If `<home>/.nightcrew/owned` exists, `SleepDisabled` is 1 and the heartbeat's mtime is older than 60 s, it runs `/usr/bin/pmset -a disablesleep 0` and logs via `logger -t nightcrew-watchdog`.
  - It only `stat`s the two user-owned files: it never reads their contents, writes, or deletes under the user's home, so a user-writable input can do no more than the sudoers rule already allows. The app removes the stale ownership file on its next reconcile.
  - It covers a hang, a crash loop, an instance outside launchd, the app job being booted out, and a reboot that stops at the login window. `SleepDisabled` persists across reboots (`/Library/Preferences/com.apple.PowerManagement.plist` → `SystemPowerSettings`).
  - If the app is still alive, its next poll re-applies the desired state (§6.3).
- `uninstall.sh` resets `disablesleep 0` only if NightCrew owned it.

## 9. Install / uninstall

One-liner (README):
```
curl -fsSL https://raw.githubusercontent.com/l0kifs/nightcrew/main/scripts/install.sh | bash
```
Also support `git clone … && make install`.

`install.sh` (idempotent, `set -euo pipefail`, clear output):
1. Check macOS ≥ 13.5, that the account is in group `admin` (`id -Gn`), and Xcode CLT (`xcode-select -p`) with `swift --version` ≥ 5.9. If CLT is missing, run `xcode-select --install` and exit with instructions. Every other failed check exits before building, with a message saying what is missing.
2. Clone or update into `~/.nightcrew/src` (skip when run from a checkout).
3. `swift build -c release` → `scripts/bundle.sh` assembles `NightCrew.app` and ad-hoc signs it.
4. `launchctl bootout gui/$UID/dev.l0kifs.nightcrew` if loaded. This stops the app without a KeepAlive restart, and its SIGTERM handler resets an owned `SleepDisabled`. Then copy to `~/Applications/NightCrew.app`.
5. All root steps run in one `sudo` invocation (one prompt), with an explanation of why it is needed. sudoers:
   ```
   # /etc/sudoers.d/nightcrew   (mode 0440, root:wheel)
   <user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
   ```
   Write it to a temp file, validate with `visudo -cf`, then install. Never touch `/etc/sudoers` itself.
   In the same invocation: `launchctl bootout system/dev.l0kifs.nightcrew.watchdog` if loaded; install `scripts/watchdog.sh` as `/Library/Application Support/NightCrew/watchdog.sh` (root:wheel 0755) and `/Library/LaunchDaemons/dev.l0kifs.nightcrew.watchdog.plist` (root:wheel 0644); `launchctl bootstrap system` it.
6. LaunchAgent `~/Library/LaunchAgents/dev.l0kifs.nightcrew.plist` (`ProgramArguments` = the app binary + `--launchd`, KeepAlive as in §8). `launchctl bootstrap gui/$UID` it, unless `launchctl print-disabled gui/$UID` lists it as disabled (Launch at login off).
7. Every `bootstrap` is retried up to 3 times, 1 s apart (it returns errno 5 transiently on macOS 26+), then confirmed with `launchctl print`. If it still fails, exit non-zero naming the job — never leave the app running without its supervisor.
8. If `SleepDisabled` is 1 and not owned, print that NightCrew stays Unmanaged until `sudo pmset -a disablesleep 0`.

`uninstall.sh`: `launchctl bootout gui/$UID/dev.l0kifs.nightcrew` (the app resets an owned `SleepDisabled` on SIGTERM). Then, in one `sudo` invocation: if `~/.nightcrew/owned` still exists, `pmset -a disablesleep 0`; `launchctl bootout system/dev.l0kifs.nightcrew.watchdog`; remove the daemon plist, `/Library/Application Support/NightCrew` and `/etc/sudoers.d/nightcrew`. Then remove the agent plist, the app and `~/.nightcrew`. An unowned (manual) `SleepDisabled` is left as it is. UserDefaults (mode, grace, floor) are removed only with `--purge`.

## 10. Menu

```
[icon]  idle: moon.zzz  |  awake: moon.stars.fill  |  error: exclamationmark.triangle   (template SF Symbols)
──────────────
Awake — 2 working (claude ×1, codex ×1)          ← or "Idle" / "Grace: 7 min left" / "Setup required" /
                                                    "Sleep disabled manually (unmanaged)" / "Paused: battery below 15%" /
                                                    "Paused: Mac too hot" / "Detection degraded"
  claude  ~/proj/foo        working
  codex   ~/proj/bar        idle
──────────────
Mode ▸  ● Auto  ○ Always awake (reverts in 7 h 52 min)  ○ Off
Grace period ▸ 0 / 5 / 10 / 30 min                ← below 10 min, a long low-CPU tool call (docker, ssh, CI wait) can be slept mid-run
Battery floor ▸ Off / 10% / 15% / 30%
☑ Sleep display when lid closes
☑ Sleep Mac when agents finish (lid closed)
☑ Launch at login                                 ← off: `launchctl disable` + `bootout` of the app job (the app quits now,
                                                    resetting an owned SleepDisabled); on: `enable` + `bootstrap`. The watchdog stays loaded.
──────────────
Quit NightCrew                                    ← restores sleep if owned
```

Optional, off by default: a notification when switching to awake or idle.

## 11. Phases

- **P1 (MVP):** everything above.
- **P2:** precise Claude state via hooks. `NightCrew.app/Contents/MacOS/nightcrew hook <agent> <busy|idle>` reads the hook JSON from stdin and writes `~/.nightcrew/sessions/<agent>-<session_id>.json` (pid = PPID, ts). Claude: `UserPromptSubmit` → busy, `Stop`/`SessionEnd` → idle. Verify that the hook process's PPID is the claude process, not an intermediate shell. A menu action merges the hooks into `~/.claude/settings.json` idempotently and backs the file up first. Hook state can only mark a session working, never idle: working = hook busy OR the §5.3 signals. Busy is refreshed by `UserPromptSubmit`, `PreToolUse` and `PostToolUse`, and expires 30 min after the last refresh, because `Stop` does not fire on a user interrupt. `Stop`, `StopFailure`, `SessionEnd` and `Notification` (permission prompt) → idle. Background commands and scheduled wakeups keep running after `Stop`. Stale files (dead pid or older than 24 h) are ignored. For Codex, check the current docs for a hooks/`notify` equivalent.
- **P3:** GitHub Releases with a prebuilt universal binary and a Homebrew tap.

## 12. Logging

Use `os.Logger(subsystem: "dev.l0kifs.nightcrew")`. Log every state transition and every pmset call with its result. Do not log per-poll noise at default level. The watchdog logs with `logger -t nightcrew-watchdog`. The README documents:
`log stream --predicate 'subsystem == "dev.l0kifs.nightcrew" OR senderImagePath ENDSWITH "logger"'`.

## 13. Acceptance criteria

1. `install.sh` on a clean macOS 13.5+ machine with CLT and an admin account produces a running menu bar app, with exactly one sudo prompt. Re-running it is safe. On macOS < 13.5 or a non-admin account it exits before building, with a message.
2. Start `claude` and give it a task. Within 2 s of submitting the prompt, `pmset -g` shows `SleepDisabled 1`. Submitting a prompt and closing the lid within 3 s leaves the agent running.
3. Close the lid while awake, with no external display. The display turns off and the agent keeps running (check its output after reopening).
4. All sessions idle or exited → after the grace period `SleepDisabled 0`. With the lid closed and `sleepWhenDone` on, the Mac sleeps.
5. An idle `claude` REPL, an idle Claude Code panel in VS Code, or an idle VS Code `codex app-server` alone does **not** keep the Mac awake past the grace period.
6. `kill -9` the app while awake with the lid closed → launchd restarts it → `SleepDisabled` stays 1 and the Mac does not sleep while the agent works. Quit from the menu → `SleepDisabled 0`.
7. `kill -STOP` the app while it owns `SleepDisabled 1` → within 180 s the watchdog sets it to 0. Double-clicking `NightCrew.app` hands off to launchd: `launchctl print gui/$UID/dev.l0kifs.nightcrew` shows the running pid. Reboot while NightCrew owns `SleepDisabled 1` and stay at the login window → within 180 s of boot it is 0.
8. A manual `sudo pmset -a disablesleep 1`, with and without a working agent, gets no NightCrew pmset call (the log shows none) and is shown as unmanaged. After a manual `disablesleep 0`, NightCrew resumes managing within 1 poll.
9. External `sudo pmset -a disablesleep 0` while an agent works → `SleepDisabled` is 1 again within 1 poll.
10. On battery below the floor, or at thermal state `serious`: not awake; with the lid closed the Mac sleeps whatever `sleepWhenDone` says; the user is notified once per pause.
11. Lid closed with an external display while an agent works for 5 min, then finishes → no `displaysleepnow` and no `sleepnow` in the log.
12. Remove `/etc/sudoers.d/nightcrew` while awake, then let the agents finish → the OFF path retries every poll and the icon shows an error. Restore the file → `SleepDisabled 0` within 60 s.
13. Always awake reverts to Auto 8 h after it was selected, including across an app restart.
14. `uninstall.sh` removes every installed file (the agent and daemon plists, the app, `/Library/Application Support/NightCrew`, the sudoers file, `~/.nightcrew`); UserDefaults stay unless `--purge`. It leaves `SleepDisabled 0` if NightCrew owned it, and unchanged otherwise.
15. `swift test` passes. Matcher and Engine have table-driven tests covering every row of §5.2, §6.2 and §6.3, including the Unmanaged and external-display rows.

## 14. Durability (stress test 2026-10-02)

Holds while:
- `sudo pmset -a disablesleep 1` keeps a lid-closed Mac awake on battery (undocumented; observed for 60 s on 2026-10-04, MacBookPro17,1, macOS 27.0; source: AC3 run after each macOS update).
- Claude Code writes `~/.claude/projects/<encoded cwd>/*.jsonl` during a turn, and Codex writes `~/.codex/sessions/…/rollout-*.jsonl` (source: AC2 and AC5 per Claude Code / Codex release).
- An idle session's CPU stays under 3.0 s per 60 s (measured max 0.79 s including background watchers, Claude Code 2.1.286; source: README calibration log).
- The root watchdog daemon is loaded (source: `launchctl print system/dev.l0kifs.nightcrew.watchdog`, checked by `install.sh` step 7).

Breaks if:
- "Detection degraded" appears for a supported agent → transcript layout changed. Owner: repo owner. Checked: on every Claude Code / Codex release. Response: update the probe; until then CPU-only, which fails toward sleeping.
- The §6.3 read-back error fires on a supported macOS → `disablesleep` changed. Owner: repo owner. Checked: AC3 on each macOS update. Response: mark that macOS unsupported in the README; the app turns itself off.
- More than 1 thermal pause per week in the log of a desk-bound Mac. Owner: repo owner. Response: move the guard from `serious` to `critical`.
- An awake true→false log line listing live non-MCP descendants (docker, ssh, …) more than once a week → work outside the process tree is being slept. Owner: repo owner. Checked: weekly from the log. Response: pull the P2 `PreToolUse`/`PostToolUse` hooks into P1.

Cost to undo: P1 is local to each Mac. `uninstall.sh` reverts it in under a minute with one sudo prompt, including the root daemon. Nothing is published beyond the repo.

Not tested (run `scripts/hw-check.sh`; results land in the git-ignored `stress-test/`): a lid-closed run longer than 60 s on battery; sleep after `disablesleep 0` with the built-in display lit (expected: stays awake on powerd's assertion); clamshell with an external display; whether `disablesleep 1` blocks the low-battery emergency sleep when Battery floor is Off; the FileVault pre-boot screen after an update reboot (the daemon cannot run before unlock); Codex matchers and transcript writes (codex is not installed on the test Mac); hook PPID (P2); behaviour on an MDM/EDR-managed Mac.
