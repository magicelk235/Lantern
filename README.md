<p align="center">
  <img src="App/Icon/AppIcon.svg" width="128" height="128" alt="Lantern icon">
</p>

<h1 align="center">Lantern</h1>

<p align="center">A native macOS IDE for <a href="https://github.com/can1357/oh-my-pi">omp</a> where agent sessions survive quits, crashes and reboots.</p>

Every session in Lantern is omp's own TUI, running in a tab. The sessions don't live in the app, though. A small daemon, `ompd`, owns every omp process and terminal, so you can quit Lantern in the middle of a tool call, open it again, and find the session exactly as you left it. While no Lantern window is open, ompd pauses the agents with omp's own `/pause`, and they pick up again when you come back.

## Features

- omp sessions and terminals keep their screens and scrollback across app restarts. If omp or ompd itself dies, the session is resumed from its file, and Lantern can continue the work that was cut off, ask you first, or leave it alone (Settings › General).
- The Agents pane (⌃⌘A) shows each session's agent tree with live activity, its background jobs and the project's named services. You can message, revive, park or kill agents, and restart or stop services.
- Tool approvals and `ask` prompts badge the Dock and post a notification while Lantern is in the background.
- The editor has syntax highlighting, git change marks in the gutter, find and replace, and language servers (sourcekit-lsp, typescript-language-server, pyright or pylsp, rust-analyzer, gopls, clangd) when they're installed. Unsaved edits survive quitting.
- Terminal tabs are owned by ompd too. Running `omp` in one turns it into a regular Lantern session.
- A menu bar extra shows how many agents are working and what's waiting for you, even with every window closed.
- Quick Look works in the Files pane, Finder's Services menu gets "Open in Lantern" and "New omp Session", and Open Session… (⇧⌘O) lists a project's saved sessions.

## Requirements

- macOS 14 or later
- [omp](https://github.com/can1357/oh-my-pi) installed and on your login shell's `PATH`

## Building from source

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and the Metal toolchain, which SwiftTerm needs for its shaders:

```sh
xcodebuild -downloadComponent MetalToolchain   # once
```

Build and test the Swift package (the daemon and every library):

```sh
swift build
swift test
```

Then generate the Xcode project and build the app:

```sh
cd App
xcodegen generate --spec project.yml
xcodebuild -project Lantern.xcodeproj -scheme Lantern -configuration Debug \
  -destination platform=macOS -derivedDataPath ~/Library/Developer/lantern/dd-main \
  -skipPackagePluginValidation build
```

### Code signing

Lantern has to be signed with a real development identity, even for local builds. macOS refuses to launch a bundled LaunchAgent whose executable has no Team ID, so an ad-hoc signed build never starts ompd and only ever shows "ompd is not reachable". `App/project.yml` signs with team `V8K8L3ZSD5`; set `DEVELOPMENT_TEAM` there to your own team.

### iCloud folders

If the checkout lives in an iCloud-synced folder such as Desktop or Documents, keep build output somewhere else. Synced folders add extended attributes to build products, and codesign rejects them. Making `.build` a symlink to a folder under `~/Library/Developer` is enough for the package, and the `xcodebuild` command above already puts derived data outside the checkout.

## Running a development build

A development build can run against its own ompd instead of the one the installed app registers:

```sh
export OMPD_HOME=/tmp/oi       # keep it short: the socket path must stay under 104 bytes
.build/debug/ompd run &        # add --omp-arg … to pass flags to every new omp session
open -n --env OMPD_HOME=/tmp/oi \
  ~/Library/Developer/lantern/dd-main/Build/Products/Debug/Lantern.app
.build/debug/ompd status
```

With `OMPD_HOME` set, Lantern doesn't register the production LaunchAgent or the menu bar extra's login item, and ompd doesn't install its bridge extension into `~/.omp/agent/extensions`. Spotlight items go into a separate domain, so they never replace the installed app's.

`scripts/dev-launchagent.sh` installs a development ompd as its own LaunchAgent (`com.magicelklabs.lantern.ompd.dev`) when you want launchd to keep it running.

## Tests

`swift test` runs the unit and integration tests. Two scripts run end-to-end checks against real omp. Both use `anthropic/claude-haiku-4-5`, so they cost a few model calls:

```sh
./scripts/acceptance.sh                  # a session survives detach, SIGTERM and a launchd restart (a few minutes)
./scripts/chaos.sh ["omp SIGKILL" ...]   # app, omp and ompd deaths at every point of a turn (about 20 minutes)
```

## Project layout

| Path | Contents |
|---|---|
| `App/` | The SwiftUI/AppKit app, the menu bar extra (`App/MenuBar`) and the XcodeGen spec |
| `Sources/ompd` | The `ompd` executable: `ompd run`, `ompd status [--json]`, `ompd --version` |
| `Sources/OmpdCore` | The daemon: session supervisors, PTY pool with screen mirrors, crash recovery, agent supervision, in-place upgrades |
| `Sources/IDEProtocol` | The wire contract between ompd and the app, and the on-disk layout |
| `Sources/IDETransport` | Length-prefixed frames over a unix socket |
| `Sources/IDEModel` | App-side models: the daemon connection, terminals, session files, crash reports |
| `Sources/IDEState` | Window and editor state in `state.sqlite` |
| `Sources/IDEEditorModel` | Editor logic without AppKit: files, dirty tracking, diffs, git |
| `Sources/IDELanguageModel` | Language server discovery and the LSP client |
| `bridge/ide-bridge.ts` | The omp extension ompd loads into every session it runs |
| `scripts/` | Release, development LaunchAgent, app icon and acceptance scripts |

## Releasing

```sh
scripts/release.sh [<version> [<build>]]   # defaults to MARKETING_VERSION and CURRENT_PROJECT_VERSION in App/project.yml
```

The script archives a universal Release build, signs it with a Developer ID and the hardened runtime, checks every signature in the bundle, and packages `Lantern-<version>.dmg`. Output goes to `~/Library/Developer/omp-ide/release` (`RELEASE_DIR` overrides it). It needs the `Developer ID Application` identity in the login keychain and network access.

Notarization and Sparkle updates are optional and controlled by environment variables:

| Variable | Purpose | Without it |
|---|---|---|
| `NOTARY_PROFILE` | `notarytool` keychain profile; the DMG is notarized and stapled | Gatekeeper rejects the download |
| `FEED_URL` | Sparkle appcast URL baked into the app; needs `SPARKLE_PUBLIC_KEY` | the app never checks for updates |
| `SPARKLE_PUBLIC_KEY` | EdDSA public key baked into the app | |
| `SPARKLE_KEY_FILE` | EdDSA private key used to sign the DMG and update the appcast | no appcast |
| `DOWNLOAD_URL_PREFIX` | Where the DMG is hosted, for the appcast | the directory of `FEED_URL` |

To set up updates, create the key pair once with Sparkle's `generate_keys` and store notarization credentials once with `xcrun notarytool store-credentials`. Never change the key pair after a build has shipped: installed copies only accept updates signed with the key they carry. Keep `release/appcast` between releases, since `generate_appcast` adds to the existing feed.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability.

## License

Lantern is source-available under the [PolyForm Shield License 1.0.0](LICENSE). You can use, modify and share it, but not to build a competing product.
