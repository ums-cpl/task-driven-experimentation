#!/usr/bin/env bash
# Status printing for task runs. print_task_run_status reads RUN_STATUS_ROWS and optional manifest for mtime.

# Print status table for rows in RUN_STATUS_ROWS (each element: "display_id\trun\trelative_path").
# Optional first arg: manifest file path for mtime comparison (only show SUCCESS/FAILED/RUNNING if marker is not older than manifest).
# Requires REPOSITORY_ROOT.
print_task_run_status() {
  local manifest_file="${1:-}"
  local row display_id run path run_folder status display_path prev_id

  echo "JOB/IDX  RUN                          PATH                                                              STATUS "
  echo "-------  ---------------------------  ----------------------------------------------------------------  -------"
  prev_id=""
  for row in "${RUN_STATUS_ROWS[@]}"; do
    display_id="${row%%	*}"
    run="${row#*	}"
    run="${run%%	*}"
    path="${row#*	}"
    path="${path#*	}"
    [[ -z "$path" ]] && continue

    if [[ "$display_id" != "$prev_id" ]]; then
      [[ -n "$prev_id" ]] && echo ""
      prev_id="$display_id"
    fi

    run_folder="$REPOSITORY_ROOT/$path/$run"
    if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
      if [[ -f "$run_folder/.run_success" ]] && [[ ! "$manifest_file" -nt "$run_folder/.run_success" ]]; then
        status=$'\033[32mSUCCESS\033[0m'
      elif [[ -f "$run_folder/.run_failed" ]] && [[ ! "$manifest_file" -nt "$run_folder/.run_failed" ]]; then
        status=$'\033[31mFAILED\033[0m'
      elif [[ -f "$run_folder/.run_begin" ]] && [[ ! "$manifest_file" -nt "$run_folder/.run_begin" ]]; then
        status=$'\033[92mRUNNING\033[0m'
      else
        status=$'\033[2mPENDING\033[0m'
      fi
    else
      if [[ -f "$run_folder/.run_success" ]]; then
        status=$'\033[32mSUCCESS\033[0m'
      elif [[ -f "$run_folder/.run_failed" ]]; then
        status=$'\033[31mFAILED\033[0m'
      elif [[ -f "$run_folder/.run_begin" ]]; then
        status=$'\033[92mRUNNING\033[0m'
      else
        status=$'\033[2mPENDING\033[0m'
      fi
    fi

    if [[ "$path" == *"/tasks/"* ]]; then
      display_path="tasks/${path#*/tasks/}"
    else
      display_path="$path"
    fi
    printf "%-7s  %-27s  %-64s  %b\n" "$display_id" "$run" "$display_path" "$status"
  done
}
