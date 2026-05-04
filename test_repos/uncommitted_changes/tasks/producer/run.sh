#!/usr/bin/env bash
set -euo pipefail
# Intentionally leave an untracked file under this run folder (not workspace ASSETS) so downstream runs with --no-uncommitted-changes see a dirty dependency scope mid-invocation.
printf 'side_effect\n' >"$PWD/uncommitted_side_effect"
