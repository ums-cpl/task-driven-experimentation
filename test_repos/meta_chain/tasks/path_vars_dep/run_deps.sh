if [[ "${RUN_ID:-}" == "second" ]]; then
  RUN_DEPENDENCIES+=("$TASK_FOLDER:first")
fi
