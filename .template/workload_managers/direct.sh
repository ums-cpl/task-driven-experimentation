#!/usr/bin/env bash
# Direct workload manager: run tasks sequentially in the current process.
# Interface: ./direct.sh "$MANIFEST_PATH" "$LOG_DIR" "$STAGE"
# Only runs JOB blocks in the given STAGE where WORKLOAD_MANAGER matches this script.

set -euo pipefail

MANIFEST="${1:?Error: Manifest path required.}"
LOG_DIR="${2:?Error: Log directory required.}"
STAGE="${3:?Error: Stage number required.}"
[[ ! -f "$MANIFEST" ]] && { echo "Error: Manifest not found: $MANIFEST" >&2; exit 1; }
mkdir -p "$LOG_DIR"

OUR_SCRIPT_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

source "${REPOSITORY_ROOT:?}/.template/scripts/wm_helpers.sh"
wm_parse_manifest_for_stage "$MANIFEST" "$STAGE" "$OUR_SCRIPT_ABS"

total_ops=0
for jid in "${WM_JOB_IDS[@]}"; do
  total_ops=$((total_ops + ${WM_JOB_TASK_COUNT["$jid"]:-0}))
done

[[ $total_ops -eq 0 ]] && exit 0

echo "Running $total_ops run(s) for stage $STAGE..."

current=0
succeeded=0
failed=0

for jid in "${WM_JOB_IDS[@]}"; do
  count=${WM_JOB_TASK_COUNT["$jid"]:-0}
  for ((idx=0; idx<count; idx++)); do
    current=$((current + 1))
    manifest_line=$(wm_get_manifest_task_line "$MANIFEST" "$jid" "$idx")
    run_name=""
    path=""
    if [[ -n "$manifest_line" ]]; then
      run_name=$(echo "$manifest_line" | cut -f2)
      path=$(echo "$manifest_line" | cut -f3)
      if [[ "$path" == tasks/* ]]; then
        display_path="${path#tasks/}"
      else
        display_path="$path"
      fi
    else
      display_path="job${jid}/idx${idx}"
      run_name="?"
    fi
    printf "[%0${#total_ops}d/%0${#total_ops}d] %s/%s ... " "$current" "$total_ops" "$display_path" "$run_name"
    if "$RUNNER" --array-manifest="$MANIFEST" --array-job-id="$jid" --array-task-id="$idx" > "$LOG_DIR/job${jid}_${idx}.log" 2>&1; then
      echo -e "\033[0;32mSUCCESS\033[0m"
      succeeded=$((succeeded + 1))
    else
      echo -e "\033[0;31mFAILED\033[0m"
      failed=$((failed + 1))
    fi
  done
done

echo "Stage $STAGE: $succeeded successes, $failed failures."
echo ""
exit $((failed > 0 ? 1 : 0))
