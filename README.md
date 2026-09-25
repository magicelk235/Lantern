# omp IDE

Native macOS IDE for [omp](https://github.com/can1357/oh-my-pi) (Swift 6, SwiftUI + AppKit, macOS 14+). The app is a thin client; the `ompd` daemon (a LaunchAgent) owns every omp process, terminal and a replayable event journal, so quitting the app never stops the agents.

## Layout

| Path | What |
|---|---|
| `Sources/OmpRPC` | omp `--mode rpc/rpc-ui` client: JSONL framing, v2 `rpc_chunk` reassembly, `OmpProcess` |
| `Sources/IDEProtocol` | daemon ↔ app wire contract and `$APP_SUPPORT` layout |
| `Sources/IDETransport` | length-prefixed frames over a unix socket (`IDEServer`, `IDEClient`, `IDERouter`) |
| `Sources/OmpdCore` | daemon: journal, manifest, session supervisor, PTY pool, ide-bridge server, power observers |
| `Sources/ompd` | `ompd run \| status [--json] \| --version` |
| `Sources/IDEModel` | app-side models: daemon connection, session TUIs that follow omp from PTY to PTY (`SessionTerminal`), terminal models (PTY attach, serial input, push-driven PTY registry) |
| `Sources/IDEEditorModel` | editor logic without AppKit: text file read/atomic save, content-hash buffer state machine (dirty, revert, external change, hot-exit restore), line diff, navigator listing, FSEvents watcher |
| `bridge/ide-bridge.ts` | omp extension loaded into every daemon-owned omp (agent registry, revive, ownership lock) |
| `App/` | XcodeGen spec + SwiftUI sources for `omp IDE.app` (embeds `ompd` and its LaunchAgent plist) |
| `scripts/` | `dev-launchagent.sh` (dev LaunchAgent), `acceptance.sh` (Phase 1 acceptance with real omp) |

## Build

The checkout lives in an iCloud-synced folder, where build products pick up extended attributes that break codesign. Keep build output outside it: `.build` is a symlink to `~/Library/Developer/omp-ide/main-build`.

```sh
xcodebuild -downloadComponent MetalToolchain   # once; SwiftTerm compiles Metal shaders
swift build && swift test                      # package + tests
./scripts/acceptance.sh                         # Phase 1 acceptance (real omp, spends a few haiku calls)

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
| 1 ompd core | done. `scripts/acceptance.sh`: after a reconnect with `since`, the replayed stream matches an always-connected client byte for byte; `launchctl kickstart -k` mid-run resumes the session (`session_exit` normal, `--resume`) |
| 2 App shell | done for Regime A: ⌘Q during a 3-level nested subagent run with a running terminal and a dirty editor, then relaunch, restores everything and the agents never notice. Regime B2 (real logout/reboot) not yet exercised |
| 3 Regime B (continuation policy, service relaunch) | not started |
| 4 Agent supervision UX (agent tree, jobs, director, session picker) | not started |
| 5 Hardening (upgrades, journal compaction, disk pressure) | not started |

Known gaps: production `SMAppService` registration hasn't run with a Developer ID build.
