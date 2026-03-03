#!/usr/bin/env bash
# Shared workload manager helpers: manifest parsing, wm_job_ids, job iteration, depends resolution.
# Source from workload manager scripts. Requires REPOSITORY_ROOT to be set.
RUNNER="${REPOSITORY_ROOT:?}/run_tasks.sh"

# Parse manifest for JOBs in the given stage that match our WM identity.
# Sets: WM_JOB_IDS (indexed array), WM_JOB_TASK_COUNT, WM_JOB_DEPENDS, WM_JOB_NAME (associative).
wm_parse_manifest_for_stage() {
  local manifest="$1"
  local stage="$2"
  local our_wm_abs="$3"
  [[ ! -f "$manifest" ]] && { echo "Error: Manifest not found: $manifest" >&2; exit 1; }

  WM_JOB_IDS=()
  unset WM_JOB_TASK_COUNT WM_JOB_DEPENDS WM_JOB_NAME 2>/dev/null || true
  declare -gA WM_JOB_TASK_COUNT WM_JOB_DEPENDS WM_JOB_NAME
  local current_job="" current_stage="" current_wm="" in_header=true
  declare -A job_id_seen=()

  while IFS= read -r line; do
    if [[ "$in_header" == true ]]; then
      [[ "$line" == "---" ]] && in_header=false
      continue
    fi
    [[ "$line" == "---" ]] && continue
    if [[ "$line" == $'JOB\t'* ]]; then
      current_job=$(echo "$line" | cut -f2)
      current_stage=""
      current_wm=""
      continue
    fi
    if [[ "$line" == STAGE* ]]; then
      current_stage=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" == JOB_NAME* ]]; then
      WM_JOB_NAME["$current_job"]=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" == WORKLOAD_MANAGER* ]]; then
      current_wm=$(echo "$line" | cut -f2)
      [[ "$current_wm" != /* ]] && current_wm="${REPOSITORY_ROOT:?}/$current_wm"
      continue
    fi
    if [[ "$line" == DEPENDS* ]]; then
      WM_JOB_DEPENDS["$current_job"]=$(echo "$line" | cut -f2)
      continue
    fi
    if [[ "$line" =~ ^[0-9]+[[:space:]] ]]; then
      if [[ "$current_stage" == "$stage" ]] && [[ "$current_wm" == "$our_wm_abs" ]]; then
        WM_JOB_TASK_COUNT["$current_job"]=$((${WM_JOB_TASK_COUNT["$current_job"]:-0} + 1))
        if [[ -z "${job_id_seen[$current_job]:-}" ]]; then
          job_id_seen["$current_job"]=1
          WM_JOB_IDS+=("$current_job")
        fi
      fi
    fi
  done < "$manifest"
}

# Load log_dir/wm_job_ids into WM_ID_MAP (manifest_job_id -> wm_job_id).
wm_load_wm_job_ids() {
  local log_dir="$1"
  unset WM_ID_MAP 2>/dev/null || true
  declare -gA WM_ID_MAP
  local wm_job_ids_file="$log_dir/wm_job_ids"
  if [[ -f "$wm_job_ids_file" ]]; then
    while IFS=$'\t' read -r mjid wmid; do
      [[ -n "$mjid" ]] && WM_ID_MAP["$mjid"]="$wmid"
    done < "$wm_job_ids_file"
  fi
}

# Resolve comma-sep manifest job ids to WM job ids using WM_ID_MAP. Outputs comma-sep list.
wm_resolve_depends() {
  local dep_list="$1"
  local dep wmid first=1
  for dep in $(echo "$dep_list" | tr ',' ' '); do
    dep=$(echo "$dep" | tr -d ' ')
    [[ -z "$dep" ]] && continue
    wmid="${WM_ID_MAP[$dep]:-}"
    [[ -z "$wmid" ]] && continue
    [[ $first -eq 1 ]] || printf ','
    printf '%s' "$wmid"
    first=0
  done
}

# Print the single task line for job_id and task_index from manifest (INDEX\tRUN_NAME\tPATH [\tKEY=VALUE...]).
# Outputs nothing if not found.
wm_get_manifest_task_line() {
  local manifest="$1"
  local job_id="$2"
  local task_index="$3"
  awk -F'\t' -v jid="$job_id" -v tid="$task_index" '
    /^JOB\t/ { cur=$2; next }
    /^[0-9]+\t/ && cur==jid && $1==tid { print; exit }
  ' "$manifest"
}

# Default SLURM sbatch template: prints the full sbatch script for one job.
# Args: JID ARRAY_MAX DEP_LINE GRES_LINE JOB_NAME
# Uses from environment: MANIFEST, LOG_DIR, SBATCH_PARTITION, SBATCH_CPUS_PER_TASK,
#   SBATCH_MEM, SBATCH_TIME (default 2:00:00), and optionally SBATCH_GRES.
_wm_slurm_default_sbatch() {
  local jid="$1" array_max="$2" dep_line="$3" gres_line="$4" job_name_val="$5"
  echo "#!/bin/bash"
  echo "#SBATCH --array=0-${array_max}"
  echo "#SBATCH --partition=${SBATCH_PARTITION}"
  [[ -n "$gres_line" ]] && echo "$gres_line"
  echo "#SBATCH --cpus-per-task=${SBATCH_CPUS_PER_TASK}"
  echo "#SBATCH --mem=${SBATCH_MEM}"
  echo "#SBATCH --time=${SBATCH_TIME:-2:00:00}"
  echo "#SBATCH --kill-on-invalid-dep=yes"
  echo "#SBATCH --job-name=${job_name_val}_${jid}"
  echo "#SBATCH --output=${LOG_DIR}/job${jid}_%a.log"
  [[ -n "$dep_line" ]] && echo "$dep_line"
  echo ""
  echo "module add Apptainer"
  echo "exec \"$RUNNER\" --array-manifest=\"$MANIFEST\" --array-job-id=\"$jid\" --array-task-id=\${SLURM_ARRAY_TASK_ID}"
}

# Submit SLURM jobs for the current stage.
# Uses from environment: REPOSITORY_ROOT, MANIFEST, LOG_DIR, SBATCH_PARTITION,
#   SBATCH_CPUS_PER_TASK, SBATCH_MEM, SBATCH_TIME (default 2:00:00), and optionally SBATCH_GRES.
# The script that sourced this file is used as the WM identity (only its JOBs are submitted).
#
# Usage: wm_slurm_submit_stage MANIFEST LOG_DIR STAGE [TEMPLATE_FN]
#   TEMPLATE_FN optional; function name that prints the sbatch script for one job.
#   Called as: TEMPLATE_FN JID ARRAY_MAX DEP_LINE GRES_LINE JOB_NAME
#   If omitted, _wm_slurm_default_sbatch is used.
wm_slurm_submit_stage() {
  local manifest="${1:?Error: Manifest path required.}"
  local log_dir="${2:?Error: Log directory required.}"
  local stage="${3:?Error: Stage number required.}"
  local template_fn="${4:-_wm_slurm_default_sbatch}"
  local our_wm_abs
  our_wm_abs="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/$(basename "${BASH_SOURCE[1]}")"

  wm_parse_manifest_for_stage "$manifest" "$stage" "$our_wm_abs"
  wm_load_wm_job_ids "$log_dir"

  local jid array_max dep_slurm dep_line gres_line job_name_val tmp slurm_id wmid
  for jid in "${WM_JOB_IDS[@]}"; do
    array_max=$((${WM_JOB_TASK_COUNT["$jid"]:-0} - 1))
    dep_slurm=""
    for wmid in $(echo "$(wm_resolve_depends "${WM_JOB_DEPENDS[$jid]:-}")" | tr ',' ' '); do
      [[ "$wmid" =~ ^[0-9]+$ ]] || continue
      [[ -n "$dep_slurm" ]] && dep_slurm+=","
      dep_slurm+="$wmid"
    done
    dep_line=""
    [[ -n "$dep_slurm" ]] && dep_line="#SBATCH --dependency=afterok:$dep_slurm"
    gres_line=""
    [[ -n "${SBATCH_GRES:-}" ]] && gres_line="#SBATCH --gres=${SBATCH_GRES}"
    job_name_val="${WM_JOB_NAME[$jid]:-run_tasks}"

    tmp=$(mktemp)
    "$template_fn" "$jid" "$array_max" "$dep_line" "$gres_line" "$job_name_val" > "$tmp"
    slurm_id=$(sbatch --parsable "$tmp")
    rm -f "$tmp"
    echo "$jid	$slurm_id" >> "$log_dir/wm_job_ids"
    echo "Submitted job $jid (SLURM $slurm_id) with ${WM_JOB_TASK_COUNT["$jid"]} task(s)"
  done
}
