#!/usr/bin/env bash
set -euo pipefail

expected_task_folder="$TASKS/path_vars"
expected_run_folder="$expected_task_folder/${RUN_ID:-}"

[[ -n "${TASK_FOLDER+x}" ]] && [[ "$TASK_FOLDER" == "$expected_task_folder" ]]
[[ -n "${RUN_FOLDER+x}" ]] && [[ "$RUN_FOLDER" == "$expected_run_folder" ]]

echo "path vars available in run.sh"
