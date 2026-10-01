# omp IDE

Native macOS IDE for [omp](https://github.com/can1357/oh-my-pi) (Swift 6, SwiftUI + AppKit, macOS 14+). Each session is omp's own TUI running in a terminal tab; the `ompd` daemon (a LaunchAgent) owns every omp TUI and terminal in its own PTYs and mirrors their screens, so quitting the app never ends a session and reopening shows exactly what was there. `omp` typed into one of the IDE's terminals is adopted as a session too (listed, paused and closed like the others; its tab is the terminal's). While no omp IDE window is open (the app quit, or running with every window closed), ompd pauses every session's agents with omp's own `/pause` (at once when the app quits or closes its last window, 3 s after it crashes) and resumes them when a window is back; a `/pause` of your own stays until you dismiss it.

## Layout

| Path | What |
|---|---|
| `Sources/IDEProtocol` | daemon ↔ app wire contract and `$APP_SUPPORT` layout |
| `Sources/IDETransport` | length-prefixed frames over a unix socket (`IDEServer`, `IDEClient`, `IDERouter`) |
| `Sources/OmpdCore` | daemon: manifest, session supervisors (omp TUIs in PTYs, respawn with `--resume`, paused while no window is open; omps typed into IDE terminals adopted as sessions), Regime-B recovery (what a dead omp left unfinished, continuation per restore policy, named-service relaunch through `omp ps`, wake stall check), agent supervision (each session's agents, jobs and pending approvals/asks folded from bridge events and pushed as `runtime`; revive/park/kill/message; named services listed and stopped/killed/restarted/re-moded), PTY pool with headless screen mirrors (terminals carry per-PTY bridge credentials), ide-bridge server + ownership lock, power observers |
| `Sources/ompd` | `ompd run \| status [--json] \| --version` |
| `Sources/IDEModel` | app-side models: daemon connection, session TUIs that follow omp from PTY to PTY (`SessionTerminal`), terminal models (PTY attach, serial input, push-driven PTY registry), a workspace's omp session files read as omp's resume picker reads them (`SessionFileListing`) |
| `Sources/IDEEditorModel` | editor logic without AppKit: text file read/atomic save, content-hash buffer state machine (dirty, revert, external change, hot-exit restore), line diff, navigator listing, FSEvents watcher |
| `bridge/ide-bridge.ts` | omp extension loaded into every daemon-owned omp and, installed globally, into every other omp (agent registry with live activity, async jobs, pending approvals and asks, revive, pause/resume via omp's `/pause`, continuation prompts, named-service events and mode changes, wake stall watch, ownership lock; terminal mode has an omp started in an IDE terminal adopted by ompd) |
| `App/` | XcodeGen spec + SwiftUI sources for `omp IDE.app` (embeds `ompd` and its LaunchAgent plist) |
| `scripts/` | `dev-launchagent.sh` (dev LaunchAgent), `acceptance.sh` (TUI-session acceptance with real omp), `chaos.sh` (Phase 3 chaos matrix with real omp) |

## Build

The checkout lives in an iCloud-synced folder, where build products pick up extended attributes that break codesign. Keep build output outside it: `.build` is a symlink to `~/Library/Developer/omp-ide/main-build`.

The app must be signed with a real identity, even locally: Background Task Management refuses to spawn a bundled LaunchAgent whose executable has no Team ID (`Bundle identifiers from launchd plist ignored because the executable doesn't have a Team ID`, then `Unable to update LWCR with smd: 22`), so an ad-hoc signed ompd never starts and the app only ever shows "ompd is not reachable". `App/project.yml` signs with the Apple Development identity of team `V8K8L3ZSD5`; change `DEVELOPMENT_TEAM` for another team. Rebuilds keep the registration (launchd binds it to the Team ID and signing identifier). A registration launchd cannot spawn (left by an ad-hoc build) is repaired by the app 12 s after launch and by Restart ompd in the notice: unregister, `launchctl bootout` of the stale job, register, up to three passes 6 s apart (BTM replaces the old record with a fresh one only a moment after the first pass).

```sh
xcodebuild -downloadComponent MetalToolchain   # once; SwiftTerm compiles Metal shaders
swift build && swift test                      # package + tests
./scripts/acceptance.sh                         # acceptance with real omp (spends a few haiku calls)
./scripts/chaos.sh ["omp SIGKILL" ...]          # chaos matrix (haiku calls; ~20 min for every row)

cd App && xcodegen generate --spec project.yml
xcodebuild -project OmpIDE.xcodeproj -scheme "omp IDE" -configuration Debug \
  -destination platform=macOS -derivedDataPath ~/Library/Developer/omp-ide/dd-main \
  -skipPackagePluginValidation build
```

## Run without installing the LaunchAgent

```sh
export OMPD_HOME=/tmp/oi                 # keep it short: the socket path must stay under 104 bytes
.build/debug/ompd run &                  # add --omp-arg … to pass flags to every new omp session
"$HOME/Library/Developer/omp-ide/dd-main/Build/Products/Debug/omp IDE.app/Contents/MacOS/omp IDE" &
.build/debug/ompd status
```

With `OMPD_HOME` set, the app does not register the production LaunchAgent (`com.omp-ide.ompd`), and the daemon does not install the lock-mode bridge into `~/.omp/agent/extensions`.

## Status

| Phase | State |
|---|---|
| 1 ompd core | done (rebuilt for TUI sessions). `scripts/acceptance.sh`: a prompt typed into the session TUI runs a nested task while a client detaches and reattaches; `launchctl kickstart -k` mid-run respawns the session with `--resume` in a new PTY that continues the old screen |
| 2 App shell | done for Regime A: session tabs are omp's TUI; ⌘Q mid-tool, relaunch → the tab reattaches and shows the finished run; editor/terminal tabs and unsaved edits restore. Regime B2 (real logout/reboot) not yet exercised |
| 3 Regime B (continuation policy, service relaunch) | done: an omp that dies is resumed and its interrupted agents are continued, held for the user (a bar in the session tab) or left, per the restore policy in Settings; named services relaunched; stalled turns after a wake aborted and continued; a session whose folder moved can be pointed at the new one. `scripts/chaos.sh`: 35/35 cells green (app, omp and ompd deaths × idle, streaming, mid-tool, mid-subagent, pending ask/approval, named service). Logout, reboot, power loss and sleep need a VM and are not staged |
| 4 Agent supervision UX (agent tree, jobs, director, session picker) | done: an Agents pane (⌃⌘A) lists each running session's agent tree with live activity, its jobs and the project's named services; agents are messaged, revived, parked or killed, services stopped, killed, restarted, re-moded and their logs followed in a terminal tab; an approval or `ask` waiting in a session badges the rail and the Dock and, in the background, posts a notification; Open Session… (⇧⌘O) lists the project's saved omp sessions with their lifecycle status and opens, focuses or resumes them. Smoked against a dev ompd with real omp (haiku); notification delivery needs the user's permission, which was not granted in the smoke |
| 5 Hardening (upgrades, disk pressure) | not started |

Known gaps: production `SMAppService` registration hasn't run with a Developer ID build. A bundled ompd that changed (rebuild, update) keeps running as the old process until launchd restarts it (`launchctl kickstart -k gui/$UID/com.omp-ide.ompd`).
