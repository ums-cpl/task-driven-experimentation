#!/usr/bin/env bash
# Usage and argument parsing.

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [KEY=VALUE ...] [TASK [TASK ...]]

Execute tasks. If no TASK is given, all tasks under tasks/ are run. TASK can be:
  - Task directory: path to dir containing run.sh (e.g. tasks/.../task1)
  - Parent directory: recursively finds all descendant dirs with run.sh
  - Wildcard: expands to matching dirs (e.g. tasks/.../*). Use !(pattern) to exclude (e.g. tasks/.../*/!(data))

  Optional suffix :TASK_RUNS sets run(s). Examples: :local, :run-{1:10}, :run* (clean only, wildcard).
  Without suffix: default TASK_RUNS "assets" for execute; cleans all runs with --clean.
  Quote the task spec if TASK_RUNS contains * or ? (e.g. "tasks/task1:run*").

Options:
  --dry-run              Create manifest without running (no workload manager invoke)
  --clean                Remove output folders for specified tasks, do not run
  --skip-succeeded       Skip task runs that have already succeeded (.run_success exists)
  --skip-verify-def      Skip verification that container image matches definition file
  --include-disabled     Run runs even if RUN_DISABLED is set in run_meta.sh
  --include-deps         Include missing dependency task runs in the invocation instead of failing
  --direct               Shortcut for RUN_WORKLOAD_MANAGER=\$TEMPLATE/workload_managers/direct.sh
  --status               Show exit state (SUCCESS/FAILED/RUNNING/PENDING) for each task run from task specs
  --status-manifest=FILE Show exit states for all task runs listed in FILE (manifest from a prior run)
  -h, --help             Show this help

Environment overrides (KEY=VALUE) are applied after each sourced file (task_meta.sh, run_meta.sh, run_env.sh, run_deps.sh), pinning overridden values so every subsequent file sees them.
EOF
}

# Parse TASK arg into task_path and run_spec. Split on first ':'.
# Used for both CLI TASK specs and RUN_DEPENDENCIES in run_deps.sh.
# Examples: "tasks/build/data:gcc" -> path="tasks/build/data", run_spec="gcc";
#           "tasks/build/data:run-{1:10}" -> path="tasks/build/data", run_spec="run-{1:10}" (range).
# Edge cases: Windows paths like C:\path break (first colon separates drive). Assumes Unix-style paths.
# Bare ":local" (no path) is invalid. Double colon "path::run" yields run_spec=":run" (literal).
parse_task_spec() {
  local arg="$1"
  if [[ "$arg" == *:* ]]; then
    printf '%s\n%s' "${arg%%:*}" "${arg#*:}"
  else
    printf '%s\n' "$arg"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --clean)
        CLEAN=true
        shift
        ;;
      --array-manifest=*)
        ARRAY_MANIFEST="${1#--array-manifest=}"
        shift
        ;;
      --array-job-id=*)
        ARRAY_JOB_ID="${1#--array-job-id=}"
        shift
        ;;
      --array-task-id=*)
        ARRAY_TASK_ID="${1#--array-task-id=}"
        shift
        ;;
      --skip-succeeded)
        SKIP_SUCCEEDED=true
        shift
        ;;
      --skip-verify-def)
        SKIP_VERIFY_DEF=true
        shift
        ;;
      --include-disabled)
        INCLUDE_DISABLED=true
        shift
        ;;
      --include-deps)
        INCLUDE_DEPS=true
        shift
        ;;
      --direct)
        ENV_OVERRIDES+=("RUN_WORKLOAD_MANAGER=${TEMPLATE}/workload_managers/direct.sh")
        shift
        ;;
      --status)
        STATUS_MODE=true
        shift
        ;;
      --status-manifest=*)
        STATUS_MANIFEST="${1#--status-manifest=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *=*)
        ENV_OVERRIDES+=("$1")
        shift
        ;;
      --*)
        echo "Error: Unrecognised option: $1" >&2
        echo "Use --help for usage." >&2
        exit 1
        ;;
      *)
        TASK_SPECS+=("$1")
        # Snapshot current overrides for this task spec (tab-separated; order preserved for later "last per key")
        if [[ ${#ENV_OVERRIDES[@]} -gt 0 ]]; then
          TASK_SPEC_OVERRIDES+=("$(IFS=$'\t'; echo "${ENV_OVERRIDES[*]}")")
        else
          TASK_SPEC_OVERRIDES+=("")
        fi
        shift
        ;;
    esac
  done
}
