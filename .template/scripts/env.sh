#!/usr/bin/env bash
# Environment file collection and dependency resolution.

# Collect files named $2 from tasks/ down to task dir, in root-to-leaf order.
# Used for task_meta.sh, run_meta.sh, run_env.sh, run_deps.sh.
get_hierarchical_files() {
  local task_dir="$1"
  local filename="$2"
  local rel_path="${task_dir#$TASKS/}"
  local files=()
  local current="$TASKS"

  [[ -f "$current/$filename" ]] && files+=("$current/$filename")
  for segment in $(echo "$rel_path" | tr '/' '\n'); do
    current="$current/$segment"
    [[ -f "$current/$filename" ]] && files+=("$current/$filename")
  done

  printf '%s\n' "${files[@]}"
}

get_task_meta_files() { get_hierarchical_files "$1" "task_meta.sh"; }
get_run_meta_files()  { get_hierarchical_files "$1" "run_meta.sh"; }
get_run_env_files()   { get_hierarchical_files "$1" "run_env.sh"; }
get_run_deps_files()  { get_hierarchical_files "$1" "run_deps.sh"; }

# Build source commands with ENV_OVERRIDES interleaved: applied once initially,
# then after each sourced file. Ensures every file in the chain sees overridden values.
build_source_cmds_with_overrides() {
  local -n _files=$1
  local override_cmds=""
  for ov in "${ENV_OVERRIDES[@]}"; do
    override_cmds+="export $ov; "
  done
  local result="$override_cmds"
  for f in "${_files[@]}"; do
    result+="source \"$f\"; $override_cmds"
  done
  echo -n "$result"
}

# Source the task_meta.sh chain in a subshell with framework vars and echo the
# requested variable. Used to resolve TASK_RUNS per task.
resolve_task_var() {
  local task_dir="$1"
  local var_name="$2"

  local meta_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")

  local source_cmds
  source_cmds=$(build_source_cmds_with_overrides meta_files)

  bash -c "
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    $source_cmds
    echo -n \"\${$var_name:-}\"
  " 2>/dev/null || true
}

# Return 1 if the variable is set (including to empty) in the task_meta.sh chain, 0 if unset.
# Used to distinguish "unset" (use default) from "explicitly set to empty".
resolve_task_var_isset() {
  local task_dir="$1"
  local var_name="$2"

  local meta_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")

  local source_cmds
  source_cmds=$(build_source_cmds_with_overrides meta_files)

  bash -c "
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    $source_cmds
    if [[ -n \"\${$var_name+x}\" ]]; then echo -n 1; else echo -n 0; fi
  " 2>/dev/null || true
}

# Source task_meta.sh then run_meta.sh chain (with RUN_ID set) in a subshell and echo
# the requested variable. Used to resolve RUN_DISABLED, RUN_CONTAINER*, RUN_WORKLOAD_MANAGER, RUN_WORKLOAD_NAME per run.
resolve_run_var() {
  local task_dir="$1"
  local run_name="$2"
  local var_name="$3"

  local meta_files=() run_meta_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_meta_files+=("$f")
  done < <(get_run_meta_files "$task_dir")

  local source_cmds_meta
  source_cmds_meta=$(build_source_cmds_with_overrides meta_files)
  local source_cmds_run_meta
  source_cmds_run_meta=$(build_source_cmds_with_overrides run_meta_files)

  bash -c "
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export RUN_ID=\"$run_name\"
    $source_cmds_meta
    $source_cmds_run_meta
    echo -n \"\${$var_name:-}\"
  " 2>/dev/null || true
}

# Return 1 if the variable is set (including to empty) in the task_meta + run_meta chain, 0 if unset.
resolve_run_var_isset() {
  local task_dir="$1"
  local run_name="$2"
  local var_name="$3"

  local meta_files=() run_meta_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_meta_files+=("$f")
  done < <(get_run_meta_files "$task_dir")

  local source_cmds_meta
  source_cmds_meta=$(build_source_cmds_with_overrides meta_files)
  local source_cmds_run_meta
  source_cmds_run_meta=$(build_source_cmds_with_overrides run_meta_files)

  bash -c "
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export RUN_ID=\"$run_name\"
    $source_cmds_meta
    $source_cmds_run_meta
    if [[ -n \"\${$var_name+x}\" ]]; then echo -n 1; else echo -n 0; fi
  " 2>/dev/null || true
}

# Get RUN_DEPENDENCIES for a task run by sourcing task_meta.sh, then run_meta.sh, then run_deps.sh chain,
# with framework vars and RUN_ID. Returns array of dependency specs.
get_task_dependencies() {
  local task_dir="$1"
  local run_name="$2"
  local -n _out=$3
  _out=()

  local meta_files=() run_meta_files=() deps_files=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && meta_files+=("$f")
  done < <(get_task_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && run_meta_files+=("$f")
  done < <(get_run_meta_files "$task_dir")
  while IFS= read -r f; do
    [[ -n "$f" ]] && deps_files+=("$f")
  done < <(get_run_deps_files "$task_dir")

  local source_cmds_meta
  source_cmds_meta=$(build_source_cmds_with_overrides meta_files)
  local source_cmds_run_meta
  source_cmds_run_meta=$(build_source_cmds_with_overrides run_meta_files)
  local source_cmds_deps
  source_cmds_deps=$(build_source_cmds_with_overrides deps_files)

  local dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && _out+=("$dep")
  done < <(bash -c "
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    $source_cmds_meta
    export RUN_ID=\"$run_name\"
    $source_cmds_run_meta
    RUN_DEPENDENCIES=()
    $source_cmds_deps
    for d in \"\${RUN_DEPENDENCIES[@]:-}\"; do
      [[ -n \"\$d\" ]] && echo \"\$d\"
    done
  " 2>/dev/null || true)
}
