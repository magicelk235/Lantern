# Security Policy

## Supported Versions

Lantern is distributed as a rolling release: only the latest version on the
`main` branch and the most recent published build receive security fixes. If
you are running an older build, update before reporting an issue.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older builds   | :x:                |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately through one of:

- **GitHub Security Advisories:** open a draft advisory at
  <https://github.com/magicelk235/Lantern/security/advisories/new>
  (preferred).
- **Email:** yehonatan.2350@gmail.com with subject line `SECURITY: lantern`.

Please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (a proof of concept if you have one).
- Affected version, macOS version, and any relevant configuration.

## What to Expect

- **Acknowledgement** within 5 business days.
- An assessment and, where confirmed, a fix timeline. Most issues are patched
  in the next release.
- Credit in the release notes once a fix ships, unless you ask to stay
  anonymous.

Please give a reasonable window to release a fix before any public disclosure.

## Scope Notes

Lantern installs `ompd`, a per-user LaunchAgent that starts omp sessions and
terminals, and talks to it over unix sockets in
`~/Library/Application Support/com.magicelklabs.lantern/`. ompd also installs an
omp extension (`ide-bridge.ts`) into `~/.omp/agent/extensions`. Reports
touching any of these are in scope: the daemon's socket protocol and its
authentication of clients and omp processes, the bridge extension, session
ownership locks, the `com.magicelklabs.lantern://` URL scheme, the Finder
Services, and the Sparkle update path.

Bugs in omp itself should be reported to
[omp](https://github.com/can1357/oh-my-pi). Do **not** include API keys, session
transcripts, or other private data in a report; redact them.
