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
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export TEMPLATE=\"$TEMPLATE\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export TASK_FOLDER=\"$task_dir\"
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
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export TEMPLATE=\"$TEMPLATE\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export TASK_FOLDER=\"$task_dir\"
    $source_cmds
    if [[ -n \"\${$var_name+x}\" ]]; then echo -n 1; else echo -n 0; fi
  " 2>/dev/null || true
}

# Cache for resolve_run_vars / resolve_run_var / resolve_run_var_isset.
# Key: task_dir<TAB>run_name<TAB>override_fingerprint<TAB>var_name
declare -A _RESOLVE_RUN_VAR_CACHE=()
declare -A _RESOLVE_RUN_VAR_ISSET_CACHE=()
declare -A RESOLVED_RUN_VARS=()
declare -A RESOLVED_RUN_VARS_ISSET=()

clear_resolve_run_var_cache() {
  _RESOLVE_RUN_VAR_CACHE=()
  _RESOLVE_RUN_VAR_ISSET_CACHE=()
}

# If KEY appears in ENV_OVERRIDES (last occurrence wins), set nameref and return 0.
# Overrides pin the final value after each sourced file, so meta need not be run.
env_override_get_pinned() {
  local key="$1"
  local -n _eogp_out=$2
  local found=0 ov
  _eogp_out=""
  for ov in "${ENV_OVERRIDES[@]:-}"; do
    [[ "$ov" == *=* ]] || continue
    if [[ "${ov%%=*}" == "$key" ]]; then
      found=1
      _eogp_out="${ov#*=}"
    fi
  done
  [[ $found -eq 1 ]]
}

_resolve_run_cache_key() {
  local task_dir="$1"
  local run_name="$2"
  local var_name="$3"
  local ov_fp="" i
  for ((i = 0; i < ${#ENV_OVERRIDES[@]}; i++)); do
    [[ $i -gt 0 ]] && ov_fp+=$'\t'
    ov_fp+="${ENV_OVERRIDES[i]}"
  done
  printf '%s\t%s\t%s\t%s' "$task_dir" "$run_name" "$ov_fp" "$var_name"
}

# Resolve one or more run vars in a single bash -c (with cache + override short-circuit).
# Sets RESOLVED_RUN_VARS[name] and RESOLVED_RUN_VARS_ISSET[name] (1 if set, else 0).
resolve_run_vars() {
  local task_dir="$1"
  local run_name="$2"
  shift 2
  local -a want=("$@")
  [[ ${#want[@]} -eq 0 ]] && return 0

  local -a need=()
  local v key pinned_val
  for v in "${want[@]}"; do
    key="$(_resolve_run_cache_key "$task_dir" "$run_name" "$v")"
    if [[ -n "${_RESOLVE_RUN_VAR_CACHE[$key]+x}" ]]; then
      RESOLVED_RUN_VARS["$v"]="${_RESOLVE_RUN_VAR_CACHE[$key]}"
      RESOLVED_RUN_VARS_ISSET["$v"]="${_RESOLVE_RUN_VAR_ISSET_CACHE[$key]}"
      continue
    fi
    if env_override_get_pinned "$v" pinned_val; then
      RESOLVED_RUN_VARS["$v"]="$pinned_val"
      RESOLVED_RUN_VARS_ISSET["$v"]=1
      _RESOLVE_RUN_VAR_CACHE["$key"]="$pinned_val"
      _RESOLVE_RUN_VAR_ISSET_CACHE["$key"]=1
      continue
    fi
    need+=("$v")
  done

  [[ ${#need[@]} -eq 0 ]] && return 0

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

  local need_q="" nv
  for nv in "${need[@]}"; do
    need_q+=" $(printf '%q' "$nv")"
  done

  local idx=0 isset_flag val
  while IFS= read -r -d '' isset_flag && IFS= read -r -d '' val; do
    v="${need[idx]}"
    key="$(_resolve_run_cache_key "$task_dir" "$run_name" "$v")"
    RESOLVED_RUN_VARS["$v"]="$val"
    RESOLVED_RUN_VARS_ISSET["$v"]="$isset_flag"
    _RESOLVE_RUN_VAR_CACHE["$key"]="$val"
    _RESOLVE_RUN_VAR_ISSET_CACHE["$key"]="$isset_flag"
    idx=$((idx + 1))
  done < <(bash -c "
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export TEMPLATE=\"$TEMPLATE\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export TASK_FOLDER=\"$task_dir\"
    export RUN_ID=\"$run_name\"
    export RUN_FOLDER=\"\$TASK_FOLDER/\$RUN_ID\"
    $source_cmds_meta
    $source_cmds_run_meta
    for __v in $need_q; do
      if [[ -n \"\${!__v+x}\" ]]; then printf '1\\0'; else printf '0\\0'; fi
      printf '%s\\0' \"\${!__v}\"
    done
  " 2>/dev/null || true)
}

# Source task_meta.sh then run_meta.sh chain (with RUN_ID set) in a subshell and echo
# the requested variable. Used to resolve RUN_DISABLED, RUN_CONTAINER*, RUN_WORKLOAD_MANAGER, RUN_WORKLOAD_NAME per run.
resolve_run_var() {
  local task_dir="$1"
  local run_name="$2"
  local var_name="$3"
  resolve_run_vars "$task_dir" "$run_name" "$var_name"
  printf '%s' "${RESOLVED_RUN_VARS[$var_name]-}"
}

# Return 1 if the variable is set (including to empty) in the task_meta + run_meta chain, 0 if unset.
resolve_run_var_isset() {
  local task_dir="$1"
  local run_name="$2"
  local var_name="$3"
  resolve_run_vars "$task_dir" "$run_name" "$var_name"
  printf '%s' "${RESOLVED_RUN_VARS_ISSET[$var_name]-0}"
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
    export REPOSITORY_ROOT=\"$REPOSITORY_ROOT\"
    export TEMPLATE=\"$TEMPLATE\"
    export ASSETS=\"$ASSETS\"
    export TASKS=\"$TASKS\"
    export WORKLOAD_MANAGERS=\"$WORKLOAD_MANAGERS\"
    export CONTAINER_MANAGERS=\"$CONTAINER_MANAGERS\"
    export INCLUDE_DEPS=\"$INCLUDE_DEPS\"
    export IGNORE_DEPS=\"$IGNORE_DEPS\"
    export TASK_FOLDER=\"$task_dir\"
    $source_cmds_meta
    export RUN_ID=\"$run_name\"
    export RUN_FOLDER=\"\$TASK_FOLDER/\$RUN_ID\"
    $source_cmds_run_meta
    RUN_DEPENDENCIES=()
    $source_cmds_deps
    for d in \"\${RUN_DEPENDENCIES[@]:-}\"; do
      [[ -n \"\$d\" ]] && echo \"\$d\"
    done
  " 2>/dev/null || true)
}
