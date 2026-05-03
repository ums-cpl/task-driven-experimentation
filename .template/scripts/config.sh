#!/usr/bin/env bash
# Configuration variables. REPOSITORY_ROOT, TEMPLATE, TASKS, ASSETS, WORKLOAD_MANAGERS, CONTAINER_MANAGERS
# are set by run_tasks.sh before sourcing.

declare -a TASK_SPECS=()
declare -a TASK_SPEC_OVERRIDES=()
declare -a TASK_SPEC_ACTIONS=()
declare -a TASK_RUN_PAIRS=()
declare -a TASK_RUN_PAIR_OVERRIDES=()
declare -a TASK_RUN_PAIR_OCC_KEYS=()
declare -a TASK_RUN_PAIR_WM=()
declare -a TASK_RUN_PAIR_WORKLOAD_NAME=()
declare -a TASK_OCC_KEYS=()
declare -a TASKS_UNIQUE=()
DRY_RUN=false
CLEAN=false
SKIP_SUCCEEDED=false
SKIP_VERIFY_DEF=false
INCLUDE_DISABLED=false
INCLUDE_DEPS=false
IGNORE_DEPS=false
AUTO_COMMIT=false
declare -a RUN_TASKS_MISSING_SPECS=()
ARRAY_MANIFEST=""
ARRAY_JOB_ID=""
ARRAY_TASK_ID=""
STATUS_MODE=false
STATUS_MANIFEST=""
declare -a RUN_STATUS_ROWS=()
declare -a ENV_OVERRIDES=()
# Number of task specs from CLI before --include-deps added any. Used so TASK_RUNS is only in manifest when explicitly set by user (suffix or KEY=VALUE).
ORIGINAL_TASK_SPEC_COUNT=0

RUN_TASKS_OUTPUT_ROOT="$REPOSITORY_ROOT/workload_logs"

# Exits 1 if REPOSITORY_ROOT is not a git repo or user.name / user.email unset.
validate_git_identity_for_auto_commit() {
  local root="${REPOSITORY_ROOT:?}"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: --auto-commit requires REPOSITORY_ROOT to be a git repository: $root" >&2
    exit 1
  fi
  if ! git -C "$root" config --get user.name >/dev/null 2>&1; then
    echo "Error: --auto-commit requires git user.name (set with: git config user.name \"...\")" >&2
    exit 1
  fi
  if ! git -C "$root" config --get user.email >/dev/null 2>&1; then
    echo "Error: --auto-commit requires git user.email (set with: git config user.email \"...\")" >&2
    exit 1
  fi
}
