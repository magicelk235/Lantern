#!/bin/sh
# Chaos matrix acceptance against real omp + anthropic/claude-haiku-4-5 (makes model
# calls; about twenty minutes). Builds ompd, then runs ChaosMatrixTests: per death (app gone, omp SIGKILL/SIGTERM, ompd
# SIGKILL/SIGTERM) one daemon with a session per moment (idle, streaming, mid-tool, mid-subagent, pending ask, pending
# approval, named service) and a terminal, restored and checked. Arguments pick rows, e.g.
# `scripts/chaos.sh "omp SIGKILL" "ompd SIGTERM"`. OMPD_ACCEPTANCE_KEEP=1 keeps each run's /tmp/oa-* directory.
set -eu
cd "$(dirname "$0")/.."
swift build --product ompd
OMPD_BINARY="$(swift build --show-bin-path)/ompd"
export OMPD_BINARY
only=""
for row in "$@"; do only="${only:+$only,}$row"; done
OMPD_CHAOS=1 OMPD_CHAOS_ONLY="$only" exec swift test --filter ChaosMatrixTests
