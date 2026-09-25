#!/bin/sh
# Acceptance against real omp + anthropic/claude-haiku-4-5 (makes model calls; ~2–4 min).
# Builds ompd, then runs DaemonAcceptanceTests, which also installs, kickstarts and removes the dev LaunchAgent
# com.omp-ide.ompd.dev (scripts/dev-launchagent.sh). Evidence is printed; OMPD_ACCEPTANCE_KEEP=1 keeps the run's
# /tmp/oa-* directory (home, journals, omp session files).
set -eu
cd "$(dirname "$0")/.."
swift build --product ompd
OMPD_BINARY="$(swift build --show-bin-path)/ompd"
export OMPD_BINARY
OMPD_ACCEPTANCE=1 exec swift test --filter DaemonAcceptanceTests
