#!/usr/bin/env bash
# Wrapper: delegates to .template/run_tasks.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$REPO_ROOT/.template/run_tasks.sh" "$@"
