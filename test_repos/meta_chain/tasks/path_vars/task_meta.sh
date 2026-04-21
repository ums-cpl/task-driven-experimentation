expected_task_folder="$TASKS/path_vars"

if [[ -n "${TASK_FOLDER+x}" ]] && [[ "$TASK_FOLDER" == "$expected_task_folder" ]]; then
  export TASK_RUNS="vars-ok"
else
  export TASK_RUNS="vars-missing"
fi
