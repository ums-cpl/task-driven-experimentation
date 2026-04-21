expected_task_folder="$TASKS/path_vars"
expected_run_folder="$expected_task_folder/${RUN_ID:-}"

if [[ "${INCLUDE_DEPS:-false}" == "true" ]] && [[ -n "${TASK_FOLDER+x}" ]] && [[ "$TASK_FOLDER" == "$expected_task_folder" ]] && [[ -n "${RUN_FOLDER+x}" ]] && [[ "$RUN_FOLDER" == "$expected_run_folder" ]]; then
  RUN_DEPENDENCIES+=("tasks/dep")
fi
