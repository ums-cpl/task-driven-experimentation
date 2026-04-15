#!/usr/bin/env bash
# Task execution and manifest creation for workload manager.

_require_abs_under_repo_root() {
  local what="$1"
  local abs="$2"
  local repo_root="${REPOSITORY_ROOT:?}"
  [[ -z "$abs" ]] && { echo "Error: $what path is empty" >&2; return 1; }
  [[ "$abs" != /* ]] && { echo "Error: $what path must be absolute: $abs" >&2; return 1; }
  [[ "$abs" != "$repo_root" && "$abs" != "$repo_root/"* ]] && { echo "Error: $what must be under REPOSITORY_ROOT ($repo_root): $abs" >&2; return 1; }
  return 0
}

_abs_to_repo_rel() {
  local abs="$1"
  local repo_root="${REPOSITORY_ROOT:?}"
  _require_abs_under_repo_root "Path" "$abs" || return 1
  if [[ "$abs" == "$repo_root" ]]; then
    echo "."
  else
    echo "${abs#"$repo_root"/}"
  fi
}

_longest_common_path_prefix() {
  local -n _paths=$1
  [[ ${#_paths[@]} -eq 0 ]] && {
    echo ""
    return
  }
  [[ ${#_paths[@]} -eq 1 ]] && {
    echo "${_paths[0]}"
    return
  }
  local ref="${_paths[0]}"
  local i k len=${#ref}
  for ((i = 1; i < ${#_paths[@]}; i++)); do
    local s="${_paths[$i]}"
    k=0
    while [[ $k -lt $len && $k -lt ${#s} && "${ref:$k:1}" == "${s:$k:1}" ]]; do
      ((k++)) || true
    done
    len=$k
  done
  local prefix="${ref:0:len}"
  [[ "$prefix" == */ ]] && {
    echo "$prefix"
    return
  }
  [[ "$prefix" == */* ]] && echo "${prefix%/*}/" || echo ""
}

_resolve_container_manager_script_for_pair() {
  local task_dir="$1"
  local run_name="$2"
  local cm
  cm=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER_MANAGER" | xargs)
  if [[ -z "$cm" ]]; then
    echo "$TEMPLATE/container_managers/apptainer.sh"
    return 0
  fi
  if [[ "$cm" != /* ]]; then
    echo "Error: RUN_CONTAINER_MANAGER must be an absolute path. Got: $cm" >&2
    return 1
  fi
  echo "$cm"
}

run_task() {
  local task_dir="$1"
  local run_name="$2"
  local run_folder="$task_dir/$run_name"

  # Collect task_meta.sh, run_meta.sh and run_env.sh files (root-to-leaf)
  local f
  local meta_files=() run_meta_files=() run_env_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_meta_files+=("$f")
  done < <(get_run_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_env_files+=("$f")
  done < <(get_run_env_files "$task_dir")

  # Build source commands with overrides interleaved
  local source_cmds_meta
  source_cmds_meta=$(build_source_cmds_with_overrides meta_files)
  local source_cmds_run_meta
  source_cmds_run_meta=$(build_source_cmds_with_overrides run_meta_files)
  local source_cmds_run_env
  source_cmds_run_env=$(build_source_cmds_with_overrides run_env_files)

  # Resolve container and manager from run_meta.sh chain (with RUN_ID)
  local container_path container_def container_gpu container_flags container_manager_rel
  container_path=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER" | xargs)
  container_def=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER_DEF" | xargs)
  container_gpu=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER_GPU" | xargs)
  container_flags=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER_FLAGS" | xargs)
  container_manager_rel=$(resolve_run_var "$task_dir" "$run_name" "RUN_CONTAINER_MANAGER" | xargs)
  if [[ -z "$container_manager_rel" ]]; then
    container_manager_script="$TEMPLATE/container_managers/apptainer.sh"
  else
    if [[ "$container_manager_rel" != /* ]]; then
      echo "Error: RUN_CONTAINER_MANAGER must be an absolute path. Got: $container_manager_rel" >&2
      return 1
    fi
    container_manager_script="$container_manager_rel"
  fi
  _require_abs_under_repo_root "CONTAINER_MANAGER" "$container_manager_script" || return 1

  # Dry-run mode: no file changes, caller prints DRY RUN status
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  # Error if RUN_CONTAINER is set but image does not exist
  if [[ -n "$container_path" ]]; then
    if [[ ! -f "$container_path" ]]; then
      echo "Error: Container image not found: $container_path" >&2
      if [[ -n "$container_def" ]]; then
        echo "Build the image using the run's container definition and your chosen runtime." >&2
      fi
      return 1
    fi

    # Verify container was built from RUN_CONTAINER_DEF via container manager
    if [[ "$SKIP_VERIFY_DEF" != true ]] && [[ -n "$container_def" ]]; then
      if [[ ! -f "$container_def" ]]; then
        echo "Error: Definition file not found: $container_def; cannot verify container. Use --skip-verify-def to run anyway." >&2
        return 1
      fi
      mkdir -p "$run_folder"
      local diff_log="$run_folder/.container_verify_diff.log"
      source "$container_manager_script"
      if ! container_verify "$container_path" "$container_def" "$diff_log"; then
        return 1
      fi
    fi
  fi

  # For metadata: was container verified? (only relevant when RUN_CONTAINER is set)
  container_verified="n/a"
  if [[ -n "$container_path" ]]; then
    if [[ "$SKIP_VERIFY_DEF" == true ]] || [[ -z "$container_def" ]]; then
      container_verified="skipped"
    else
      container_verified="true"
    fi
  fi

  # Build overrides section for .run_metadata (embed KEY=VALUE lines in generated script)
  local overrides_meta=""
  local ov
  for ov in "${ENV_OVERRIDES[@]}"; do
    escaped_ov=$(printf '%s' "$ov" | sed 's/\\/\\\\/g; s/"/\\"/g')
    overrides_meta+="  echo \"$escaped_ov\"
"
  done

  # Get container exec snippet from manager (for re-exec into container)
  local container_exec_snippet_output=""
  if [[ -f "$container_manager_script" ]]; then
    container_exec_snippet_output=$(REPOSITORY_ROOT="$REPOSITORY_ROOT" source "$container_manager_script" 2>/dev/null && container_exec_snippet)
  fi

  # Create runner script (self-contained for manual re-runs; invokes container manager when RUN_CONTAINER set)
  mkdir -p "$run_folder"
  local runner_script="$run_folder/.run_script.sh"
  cat > "$runner_script" << RUNNER_SCRIPT
#!/usr/bin/env bash
set -euo pipefail
export ASSETS="$ASSETS"
export TASKS="$TASKS"
export WORKLOAD_MANAGERS="$WORKLOAD_MANAGERS"
export CONTAINER_MANAGERS="$CONTAINER_MANAGERS"
export CONTAINER_MANAGER="$container_manager_script"
export REPOSITORY_ROOT="$REPOSITORY_ROOT"
export RUN_FOLDER="$run_folder"

# Remove all files in run folder except this script
find "\$RUN_FOLDER" -mindepth 1 -maxdepth 1 ! -name '.run_script.sh' -exec rm -rf {} +

# Source task_meta.sh chain (task configuration, e.g. TASK_RUNS)
$source_cmds_meta

# Source run_meta.sh chain and export RUN_* as CONTAINER* for container manager scripts
export RUN_ID="$run_name"
$source_cmds_run_meta
export CONTAINER="\${RUN_CONTAINER:-}"
export CONTAINER_DEF="\${RUN_CONTAINER_DEF:-}"
export CONTAINER_GPU="\${RUN_CONTAINER_GPU:-}"
export CONTAINER_FLAGS="\${RUN_CONTAINER_FLAGS:-}"
export CONTAINER_MANAGER="\${RUN_CONTAINER_MANAGER:-$container_manager_script}"

$container_exec_snippet_output

# Source run_env.sh chain (runtime helpers)
$source_cmds_run_env

exec > >(tee "\$RUN_FOLDER/.run_output.log") 2>&1
cd "\$RUN_FOLDER"
{
  echo "=== git ==="
  if [[ -n "\${REPOSITORY_ROOT:-}" ]] && git -C "\$REPOSITORY_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "\$REPOSITORY_ROOT" status 2>/dev/null || true
    echo "---"
    git -C "\$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || true
  else
    echo "not a git repository"
  fi
  echo ""
  echo "=== overrides ==="
$overrides_meta  echo ""

  echo "=== framework variables ==="
  echo "RUN_DISABLED=\${RUN_DISABLED:-}"
  echo "RUN_CONTAINER=\${RUN_CONTAINER:-}"
  echo "RUN_CONTAINER_DEF=\${RUN_CONTAINER_DEF:-}"
  echo "RUN_CONTAINER_GPU=\${RUN_CONTAINER_GPU:-}"
  echo "RUN_CONTAINER_FLAGS=\${RUN_CONTAINER_FLAGS:-}"
  echo "RUN_CONTAINER_MANAGER=\${RUN_CONTAINER_MANAGER:-}"
  echo "RUN_WORKLOAD_MANAGER=\${RUN_WORKLOAD_MANAGER:-}"
  echo "RUN_WORKLOAD_NAME=\${RUN_WORKLOAD_NAME:-}"
  echo "RUN_ID=\${RUN_ID:-}"
  echo ""

  echo "=== container ==="
  echo "container: ${container_path:-}"
  echo "container_def: ${container_def:-}"
  echo "verified: $container_verified"
  echo ""
  echo "=== environment ==="
  env 2>/dev/null | sort || true
  echo ""
  echo "=== hardware ==="
  echo "--- cpu ---"
  echo "cores: \$(nproc 2>/dev/null || echo N/A)"
  if command -v lscpu >/dev/null 2>&1; then
    lscpu 2>/dev/null || true
  else
    grep -E '^model name|^cpu MHz' /proc/cpuinfo 2>/dev/null | head -4 || echo "N/A"
  fi
  echo ""
  echo "--- memory ---"
  if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null || true
  else
    grep MemTotal /proc/meminfo 2>/dev/null || echo "N/A"
  fi
  echo ""
  echo "--- gpu ---"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,memory.used,clocks.current.graphics --format=csv 2>/dev/null || echo "N/A"
  else
    echo "N/A"
  fi
} > "\$RUN_FOLDER/.run_metadata"
date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_begin"
set +e
( . "$task_dir/run.sh" )
task_exit=\$?
set -e
if [[ \$task_exit -eq 0 ]]; then
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_success"
else
  date "+%Y-%m-%d %H:%M:%S %Z" > "\$RUN_FOLDER/.run_failed"
  exit \$task_exit
fi
RUNNER_SCRIPT
  chmod u+x "$runner_script"

  # Execute run: runner script tees to .run_output.log; suppress console when invoked from run_tasks.sh
  bash "$runner_script" > /dev/null 2>&1
  return $?
}

# True if WM path denotes direct.sh (no mixing with cluster WMs).
is_direct_wm() {
  local wm="$1"
  [[ "$wm" == *"/direct.sh" ]]
}

# Creates a single manifest file. Group by (stage, WORKLOAD_NAME, WORKLOAD_MANAGER).
# Format: header (SKIP_VERIFY_DEF, ---), then JOB blocks with STAGE, WORKLOAD_NAME, WORKLOAD_MANAGER, DEPENDS, task lines.
# Errors if both direct.sh and other WMs appear (mixing not supported).
# When RUN_TASKS_PRECOMPUTED_TASK_STAGE and RUN_TASKS_PRECOMPUTED_MAX_STAGE are set, uses them.
create_manifest() {
  local -n _task_run_pairs=$1
  local -n _tasks_unique=$2
  local manifest_path job_safe inv_dir n

  declare -A task_stage
  declare -A task_dep_checks
  local max_stage=0
  if [[ -n "${RUN_TASKS_PRECOMPUTED_MAX_STAGE+1}" ]]; then
    local k
    for k in "${!RUN_TASKS_PRECOMPUTED_TASK_STAGE[@]}"; do
      task_stage["$k"]="${RUN_TASKS_PRECOMPUTED_TASK_STAGE[$k]}"
    done
    max_stage=$RUN_TASKS_PRECOMPUTED_MAX_STAGE
    unset RUN_TASKS_PRECOMPUTED_TASK_STAGE RUN_TASKS_PRECOMPUTED_MAX_STAGE
  else
    compute_stages "$2" "$1" task_stage max_stage task_dep_checks
  fi

  # Group pair indices by (stage, WORKLOAD_NAME, WORKLOAD_MANAGER)
  declare -A group_keys=()
  declare -A group_pairs=()
  local has_direct=false
  local has_non_direct=false
  local idx pair occ_key st wm wname key
  for ((idx=0; idx<${#_task_run_pairs[@]}; idx++)); do
    pair="${_task_run_pairs[$idx]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$idx]:-}"
    st="${task_stage[$occ_key]:--1}"
    wm="${TASK_RUN_PAIR_WM[$idx]:-$TEMPLATE/workload_managers/direct.sh}"
    wname="${TASK_RUN_PAIR_WORKLOAD_NAME[$idx]:-}"

    # Validate that all paths required for execution are under REPOSITORY_ROOT.
    local task_dir="${pair%%	*}"
    local run_name="${pair#*	}"
    _require_abs_under_repo_root "TASK" "$task_dir" || exit 1
    _require_abs_under_repo_root "WORKLOAD_MANAGER" "$wm" || exit 1
    local cm_script
    cm_script="$(_resolve_container_manager_script_for_pair "$task_dir" "$run_name")" || exit 1
    _require_abs_under_repo_root "CONTAINER_MANAGER" "$cm_script" || exit 1

    is_direct_wm "$wm" && has_direct=true || has_non_direct=true
    key="${st}	${wname}	${wm}"
    group_keys["$key"]=1
    group_pairs["$key"]="${group_pairs["$key"]:+${group_pairs["$key"]} }$idx"
  done
  if [[ "$has_direct" == true && "$has_non_direct" == true ]]; then
    echo "Error: Mixing .template/workload_managers/direct.sh with other workload managers is not supported. Use either only direct.sh or only other workload managers." >&2
    exit 1
  fi

  # Order groups by stage, then by first occurrence (min pair index) for stable spec order
  local -a ordered_keys=()
  local stage stage_keys key min_idx idx
  for stage in $(seq 0 "$max_stage"); do
    stage_keys=()
    for key in "${!group_keys[@]}"; do
      [[ "$key" == "$stage"* ]] || continue
      stage_keys+=("$key")
    done
    # Sort by minimum pair index in group so order follows spec order
    while IFS= read -r key; do
      [[ -n "$key" ]] && ordered_keys+=("$key")
    done < <(
      for key in "${stage_keys[@]}"; do
        min_idx=999999
        for idx in ${group_pairs[$key]:-}; do
          [[ $idx -lt $min_idx ]] && min_idx=$idx
        done
        printf '%d\t%s\n' "${min_idx}" "$key"
      done | sort -n -t$'\t' -k1,1 | cut -f2-
    )
  done

  # Only assign job_id to blocks that have at least one run to emit (SKIP_SUCCEEDED filter)
  local -a emitted_keys=()
  local idx pair
  for key in "${ordered_keys[@]}"; do
    local -a indices=()
    read -ra indices <<< "${group_pairs[$key]:-}"
    local has_any=false
    for idx in "${indices[@]}"; do
      [[ "$SKIP_SUCCEEDED" != true ]] || ! is_task_run_succeeded "${_task_run_pairs[$idx]%%	*}" "${_task_run_pairs[$idx]#*	}" && { has_any=true; break; }
    done
    [[ "$has_any" == true ]] && emitted_keys+=("$key")
  done

  declare -A key_to_job_id=()
  local job_id=0
  for key in "${emitted_keys[@]}"; do
    key_to_job_id["$key"]=$job_id
    ((job_id++)) || true
  done

  # Per-stage list of job ids (for DEPENDS), only emitted blocks
  declare -A stage_job_ids=()
  for key in "${emitted_keys[@]}"; do
    stage="${key%%	*}"
    jid="${key_to_job_id[$key]}"
    stage_job_ids["$stage"]="${stage_job_ids[$stage]:+${stage_job_ids[$stage]},}$jid"
  done

  # Compute display workload names at manifest generation time.
  # For each emitted job, compute its common task-path prefix, then trim the
  # manifest-wide common root and append the remainder to WORKLOAD_NAME.
  declare -A key_to_job_prefix=()
  declare -A key_to_workload_name=()
  local -a all_job_prefixes=()
  local -a path_arr=()
  local global_prefix="" job_prefix trimmed_prefix suffix_display
  for key in "${emitted_keys[@]}"; do
    local -a indices=()
    read -ra indices <<< "${group_pairs[$key]:-}"
    path_arr=()
    for idx in "${indices[@]}"; do
      [[ "$SKIP_SUCCEEDED" == true ]] && is_task_run_succeeded "${_task_run_pairs[$idx]%%	*}" "${_task_run_pairs[$idx]#*	}" && continue
      pair="${_task_run_pairs[$idx]}"
      task_dir="${pair%%	*}"
      path_arr+=("$(_abs_to_repo_rel "$task_dir")")
    done
    job_prefix=$(_longest_common_path_prefix path_arr)
    key_to_job_prefix["$key"]="$job_prefix"
    all_job_prefixes+=("$job_prefix")
  done
  global_prefix=$(_longest_common_path_prefix all_job_prefixes)
  for key in "${emitted_keys[@]}"; do
    wname="${key#*	}"
    wname="${wname%%	*}"
    key_to_workload_name["$key"]="$wname"
    if [[ -n "$global_prefix" ]]; then
      trimmed_prefix="${key_to_job_prefix[$key]#"$global_prefix"}"
      if [[ -n "$trimmed_prefix" ]]; then
        suffix_display="${trimmed_prefix#/}"
        suffix_display="${suffix_display%/}"
        [[ -n "$suffix_display" ]] && key_to_workload_name["$key"]="${wname}: .../${suffix_display}/..."
      fi
    fi
  done

  # Invocation dir name: first non-empty WORKLOAD_NAME in manifest, else run_tasks
  job_safe="run_tasks"
  for key in "${emitted_keys[@]}"; do
    wname="${key#*	}"
    wname="${wname%%	*}"
    if [[ -n "$wname" ]]; then
      job_safe="${wname//[\/ ]/_}"
      break
    fi
  done
  inv_dir="$RUN_TASKS_OUTPUT_ROOT/${job_safe}"
  if [[ -d "$inv_dir" ]]; then
    n=1
    while [[ -d "$RUN_TASKS_OUTPUT_ROOT/${job_safe}_${n}" ]]; do
      n=$((n + 1))
    done
    inv_dir="$RUN_TASKS_OUTPUT_ROOT/${job_safe}_${n}"
  fi

  print_manifest_content() {
    echo "SKIP_VERIFY_DEF=$SKIP_VERIFY_DEF"
    echo "---"
    local key task_dir run_name overrides dep_list prev_stage i block_started=false
    for key in "${emitted_keys[@]}"; do
      [[ "$block_started" == true ]] && echo "---"
      block_started=true
      stage="${key%%	*}"
      wm="${key#*	}"
      wm="${wm#*	}"
      job_id="${key_to_job_id[$key]}"
      prev_stage=$((stage - 1))
      dep_list=""
      [[ $prev_stage -ge 0 ]] && dep_list="${stage_job_ids[$prev_stage]:-}"

      local -a indices=()
      read -ra indices <<< "${group_pairs[$key]:-}"
      local -a to_emit=()
      for idx in "${indices[@]}"; do
        [[ "$SKIP_SUCCEEDED" == true ]] && is_task_run_succeeded "${_task_run_pairs[$idx]%%	*}" "${_task_run_pairs[$idx]#*	}" && continue
        to_emit+=("$idx")
      done
      [[ ${#to_emit[@]} -eq 0 ]] && continue

      echo "JOB	$job_id"
      echo "STAGE	$stage"
      echo "WORKLOAD_NAME	${key_to_workload_name[$key]}"
      echo "WORKLOAD_MANAGER	$(_abs_to_repo_rel "$wm")"
      echo "DEPENDS	$dep_list"
      i=0
      for idx in "${to_emit[@]}"; do
        pair="${_task_run_pairs[$idx]}"
        task_dir="${pair%%	*}"
        run_name="${pair#*	}"
        task_path="$(_abs_to_repo_rel "$task_dir")"
        overrides="${TASK_RUN_PAIR_OVERRIDES[$idx]:-}"
        if [[ -n "$overrides" ]]; then
          printf '%d\t%s\t%s\t%s\n' "$i" "$run_name" "$task_path" "$overrides"
        else
          printf '%d\t%s\t%s\n' "$i" "$run_name" "$task_path"
        fi
        i=$((i + 1))
      done
    done
  }

  if [[ "${DRY_RUN:-false}" == true ]]; then
    print_manifest_content
    return 0
  fi

  mkdir -p "$inv_dir"
  manifest_path="$inv_dir/manifest"
  print_manifest_content > "$manifest_path"

  # Helper to show status for this invocation's manifest (execs run_tasks.sh with --status-manifest)
  cat > "$inv_dir/status.sh" << 'STATUS_HELPER'
#!/usr/bin/env bash
set -euo pipefail
exec "__RUN_TASKS_SCRIPT__" --status-manifest="$(dirname "\$0")/manifest"
STATUS_HELPER
  # Inject wrapper path without expanding $0/command-substitutions from inside the helper.
  sed -i "s#__RUN_TASKS_SCRIPT__#${RUN_TASKS_SCRIPT//\//\\/}#g" "$inv_dir/status.sh"
  chmod +x "$inv_dir/status.sh"

  echo "$manifest_path"
}

# Run a single task from a manifest (array execution mode).
# Requires --array-job-id and --array-task-id. Looks up job block and task within it.
run_array_task() {
  local manifest="$1"
  local job_id="$2"
  local task_id="$3"
  local line task_dir

  # Parse header: SKIP_VERIFY_DEF only until --- (per-run overrides are in run lines)
  while IFS= read -r line; do
    [[ "$line" == "---" ]] && break
    if [[ "$line" == SKIP_VERIFY_DEF=* ]]; then
      SKIP_VERIFY_DEF="${line#SKIP_VERIFY_DEF=}"
    fi
  done < "$manifest"

  # Find job block for job_id, then task at task_id. Format: INDEX RUN PATH [TAB KEY=VALUE...]
  local manifest_line run_name
  manifest_line=$(awk -F'\t' -v jid="$job_id" -v tid="$task_id" '
    /^JOB\t/ { cur=$2; next }
    /^[0-9]+\t/ && cur==jid && $1==tid { print; exit }
  ' "$manifest")
  if [[ -z "$manifest_line" ]]; then
    echo "Error: No run found for job $job_id index $task_id in manifest $manifest" >&2
    return 1
  fi
  ENV_OVERRIDES=()
  local -a fields=()
  IFS=$'\t' read -ra fields <<< "$manifest_line"
  run_name="${fields[1]}"
  task_dir="${fields[2]}"
  [[ "$task_dir" != /* ]] && task_dir="$REPOSITORY_ROOT/$task_dir"
  local f
  for ((f=3; f<${#fields[@]}; f++)); do
    [[ -n "${fields[$f]}" ]] && [[ "${fields[$f]}" == *=* ]] && ENV_OVERRIDES+=("${fields[$f]}")
  done

  run_task "$task_dir" "$run_name"
}
