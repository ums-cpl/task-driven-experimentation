expected_task_folder="$TASKS/path_vars"
expected_run_folder="$expected_task_folder/${RUN_ID:-}"

if [[ -n "${TASK_FOLDER+x}" ]] && [[ "$TASK_FOLDER" == "$expected_task_folder" ]] && [[ -n "${RUN_FOLDER+x}" ]] && [[ "$RUN_FOLDER" == "$expected_run_folder" ]]; then
  export RUN_WORKLOAD_NAME="path-vars-ok"
else
  export RUN_WORKLOAD_NAME="path-vars-missing"
fi
