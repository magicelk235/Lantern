# omp IDE

Native macOS IDE for [omp](https://github.com/can1357/oh-my-pi) (Swift 6, SwiftUI + AppKit, macOS 14+). Each session is omp's own TUI running in a terminal tab; the `ompd` daemon (a LaunchAgent) owns every omp TUI and terminal in its own PTYs and mirrors their screens, so quitting the app never ends a session and reopening shows exactly what was there. `omp` typed into one of the IDE's terminals is adopted as a session too (listed, paused and closed like the others; its tab is the terminal's). While no omp IDE window is open (the app quit, or running with every window closed), ompd pauses every session's agents with omp's own `/pause` (at once when the app quits or closes its last window, 3 s after it crashes) and resumes them when a window is back; a `/pause` of your own stays until you dismiss it.

## Layout

| Path | What |
|---|---|
| `Sources/IDEProtocol` | daemon ↔ app wire contract and `$APP_SUPPORT` layout |
| `Sources/IDETransport` | length-prefixed frames over a unix socket (`IDEServer`, `IDEClient`, `IDERouter`) |
| `Sources/OmpdCore` | daemon: manifest, session supervisors (omp TUIs in PTYs, respawn with `--resume`, paused while no window is open; omps typed into IDE terminals adopted as sessions), Regime-B recovery (what a dead omp left unfinished, continuation per restore policy, named-service relaunch through `omp ps`, wake stall check), agent supervision (each session's agents, jobs and pending approvals/asks folded from bridge events and pushed as `runtime`; revive/park/kill/message; named services listed and stopped/killed/restarted/re-moded), PTY pool with headless screen mirrors (terminals carry per-PTY bridge credentials), ide-bridge server + ownership lock, power observers, hardening (the omp version each spawn runs and the one installed at its path, `session.restart`, free-space and snapshot-failure notices, `omp gc` report and clean-up) |
| `Sources/ompd` | `ompd run \| status [--json] \| --version` |
| `Sources/IDEModel` | app-side models: daemon connection, session TUIs that follow omp from PTY to PTY (`SessionTerminal`), terminal models (PTY attach, serial input, push-driven PTY registry), a workspace's omp session files read as omp's resume picker reads them (`SessionFileListing`), local crash reports of ompd and the app (`CrashReport`) |
| `Sources/IDEEditorModel` | editor logic without AppKit: text file read/atomic save, content-hash buffer state machine (dirty, revert, external change, hot-exit restore), line diff, navigator listing, FSEvents watcher |
| `bridge/ide-bridge.ts` | omp extension loaded into every daemon-owned omp and, installed globally, into every other omp (agent registry with live activity, async jobs, pending approvals and asks, revive, pause/resume via omp's `/pause`, continuation prompts, named-service events and mode changes, wake stall watch, redial after an in-place ompd upgrade, ownership lock; terminal mode has an omp started in an IDE terminal adopted by ompd) |
| `App/` | XcodeGen spec + SwiftUI sources for `omp IDE.app` (embeds `ompd` and its LaunchAgent plist) |
| `scripts/` | `dev-launchagent.sh` (dev LaunchAgent), `acceptance.sh` (TUI-session acceptance with real omp), `chaos.sh` (Phase 3 chaos matrix with real omp), `release.sh` (signed universal DMG, notarization, Sparkle appcast) |

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

Debug builds the active architecture with Xcode's defaults. Release builds are universal (`arm64 x86_64`) and compile ompd and its package modules (`OmpdCore`) with `-Osize`.

## Release

```sh
scripts/release.sh [<version> [<build>]]   # defaults: MARKETING_VERSION, CURRENT_PROJECT_VERSION in App/project.yml
```

Prerequisites: Xcode, `xcodegen`, the Metal toolchain, the `Developer ID Application: Bella Cohen (V8K8L3ZSD5)` identity with its private key in the login keychain, and network (package resolution, Apple's timestamp server). Output goes to `~/Library/Developer/omp-ide/release` (outside iCloud; `RELEASE_DIR` moves it), derived data to `~/Library/Developer/omp-ide/dd-release` (`DERIVED_DATA`).

The script runs `xcodegen`, archives the Release configuration, exports it with Developer ID signing and the hardened runtime (`export/omp IDE.app`), then verifies it and stops on any signing problem: `codesign --verify --deep --strict`; every Mach-O in the bundle (app, ompd, Sparkle and its helpers) signed by the Developer ID of team `V8K8L3ZSD5` with the hardened runtime, a secure timestamp and no `get-task-allow`; ompd signed as `com.omp-ide.ompd` and sealed at `Contents/MacOS/ompd`, its LaunchAgent plist sealed at `Contents/Library/LaunchAgents/` with `BundleProgram` pointing at it; app, ompd and Sparkle universal. It prints `spctl`'s verdict (an unnotarized build is rejected as `Unnotarized Developer ID`), builds `omp-IDE-<version>.dmg` (the app and an `/Applications` link), signs it and checks the mounted image. Steps whose inputs are missing are skipped and listed at the end.

| Variable | Does | Without it |
|---|---|---|
| `FEED_URL` | Sparkle appcast URL baked into the app (`SUFeedURL`); needs `SPARKLE_PUBLIC_KEY` | the app never starts Sparkle: no checks, no prompts, no Check for Updates… |
| `SPARKLE_PUBLIC_KEY` | EdDSA public key baked into the app (`SUPublicEDKey`) | — |
| `NOTARY_PROFILE` | `notarytool submit --wait` with this keychain profile, then `stapler staple` on the DMG | not notarized: Gatekeeper rejects the download |
| `SPARKLE_KEY_FILE` | EdDSA private key file; must match `SPARKLE_PUBLIC_KEY`. `sign_update` prints the DMG's signature and `generate_appcast` adds its item to `release/appcast/<feed file name>` | no appcast |
| `DOWNLOAD_URL_PREFIX` | where the DMG is served, for the appcast enclosure | `FEED_URL`'s directory |

Setting up the feed later (the tools are Sparkle's, under `~/Library/Developer/omp-ide/dd-release/SourcePackages/artifacts/sparkle/Sparkle/bin` after one release run):

1. Once: `generate_keys` creates the EdDSA key pair in the login keychain and prints the public key; `generate_keys -x <file>` exports the private key for `SPARKLE_KEY_FILE` (keep it out of the repo). Never change the pair after a build ships: installed apps only accept updates signed with the key they carry.
2. Once: `xcrun notarytool store-credentials <profile> --apple-id <id> --team-id V8K8L3ZSD5` stores the notarization credentials as `<profile>`.
3. Each release: `FEED_URL=https://…/appcast.xml SPARKLE_PUBLIC_KEY=<public key> SPARKLE_KEY_FILE=<file> NOTARY_PROFILE=<profile> scripts/release.sh <version> <build>`, with `<build>` higher than every shipped build; then upload the DMG and the appcast. Keep `release/appcast` between releases: `generate_appcast` adds to the appcast already there.

With a feed, Sparkle checks on its own schedule (it asks on the second launch), downloads an update in the background and installs it when the app quits. ompd keeps running from the replaced bundle (launchd keeps the old binary's inode mapped; the registration is keyed on the bundle path, Team ID and identifier, which an update keeps), and the new app's first hello upgrades it.

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
| 5 Hardening (upgrades, disk pressure) | done: ompd upgrades in place on the next app hello after its executable changed (`execve` handover: same pid, omps, PTYs and locks; bridges redial), else restarts gracefully when settled; an app refused by an older ompd restarts it when idle or offers Restart Now / When Idle; omp upgrades show a Restart Session bar; low-disk and write-failure notices; Settings › Storage runs `omp gc` (never `--archive`); local crash-report notices; Sparkle (off until a feed is set) and `scripts/release.sh` (Developer ID, universal DMG). Not exercised: notarization, a real Sparkle update, the production kickstart of the installed ompd; the new app surfaces were not checked on screen |

Known gaps: production `SMAppService` registration hasn't run with a Developer ID build. Sessions started before bridge revision 9 cannot redial, so the first ompd upgrade from today's installed daemon is a graceful restart (Regime B2), taken when every session is settled or on Restart Now.
