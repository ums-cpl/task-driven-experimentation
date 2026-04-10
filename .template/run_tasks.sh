#!/usr/bin/env bash
# Runner script for tasks. Executes tasks with proper environment setup,
# logging, and success tracking. See readme.md for design details.

set -euo pipefail

trap 'echo ""; echo "Interrupted. Aborting run." >&2; exit 130' INT

# Module roots (the template directory containing this runner).
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_ROOT="$(cd "$TEMPLATE_DIR/.." && pwd)"

# Caller-injected "instance roots". Defaults make this repo self-contained.
: "${REPOSITORY_ROOT:="$MODULE_ROOT"}"
: "${TASKS:="$REPOSITORY_ROOT/tasks"}"
: "${ASSETS:="$REPOSITORY_ROOT/assets"}"

# The template dir to use for scripts/workload-managers/container-managers.
: "${TEMPLATE:="$TEMPLATE_DIR"}"
: "${RUN_TASKS_LIB:="$TEMPLATE/scripts"}"

WORKLOAD_MANAGERS="$TEMPLATE/workload_managers"
CONTAINER_MANAGERS="$TEMPLATE/container_managers"

# Wrapper path for re-invocation (cluster jobs do not inherit env vars).
: "${RUN_TASKS_SCRIPT:="$REPOSITORY_ROOT/run_tasks.sh"}"

source "$RUN_TASKS_LIB/config.sh"
source "$RUN_TASKS_LIB/args.sh"
source "$RUN_TASKS_LIB/run_spec.sh"
source "$RUN_TASKS_LIB/task_run_resolution.sh"
source "$RUN_TASKS_LIB/env.sh"
source "$RUN_TASKS_LIB/stages.sh"
source "$RUN_TASKS_LIB/status.sh"
source "$RUN_TASKS_LIB/execution.sh"
source "$RUN_TASKS_LIB/main.sh"

main "$@"
