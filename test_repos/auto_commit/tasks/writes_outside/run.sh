#!/usr/bin/env bash
set -euo pipefail
echo in_run > in_run_only.txt
echo leak > "$REPOSITORY_ROOT/LEAK.auto_commit_test"
