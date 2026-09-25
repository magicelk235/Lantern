#!/bin/sh
# Acceptance for TUI sessions against real omp + anthropic/claude-haiku-4-5 (makes model calls; a few
# minutes). Builds ompd, then runs DaemonAcceptanceTests: a session's TUI runs a nested task subagent (/bin/sleep 10)
# typed in through pty.write while a client detaches and re-attaches; SIGTERM takes the graceful path; then the dev
# LaunchAgent com.omp-ide.ompd.dev (scripts/dev-launchagent.sh, installed and removed by the test) is kickstarted
# mid-run and the session comes back with --resume in a new PTY. Evidence is printed; OMPD_ACCEPTANCE_KEEP=1 keeps the
# run's /tmp/oa-* directory (home, PTY snapshots, omp session files).
set -eu
cd "$(dirname "$0")/.."
swift build --product ompd
OMPD_BINARY="$(swift build --show-bin-path)/ompd"
export OMPD_BINARY
OMPD_ACCEPTANCE=1 exec swift test --filter DaemonAcceptanceTests
