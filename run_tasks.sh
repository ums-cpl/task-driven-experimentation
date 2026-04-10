#!/usr/bin/env bash
set -euo pipefail

WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPOSITORY_ROOT=$WRAPPER_DIR
export TASKS=$REPOSITORY_ROOT/tasks
export ASSETS=$REPOSITORY_ROOT/assets
export TEMPLATE=$REPOSITORY_ROOT/.template
export RUN_TASKS_SCRIPT=$WRAPPER_DIR/run_tasks.sh

exec "$TEMPLATE/run_tasks.sh" "$@"
