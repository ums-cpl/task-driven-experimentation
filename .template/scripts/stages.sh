#!/usr/bin/env bash
# Stage computation and dependency verification.

# Repo-relative path for an absolute path under REPOSITORY_ROOT (for git pathspecs).
_repo_rel_from_abs() {
  local abs="$1"
  local root="${REPOSITORY_ROOT:?}"
  [[ -z "$abs" ]] && return 1
  [[ "$abs" != /* ]] && return 1
  [[ "$abs" != "$root" && "$abs" != "$root/"* ]] && return 1
  if [[ "$abs" == "$root" ]]; then
    echo "."
  else
    echo "${abs#"$root"/}"
  fi
}

# List run name basenames for one resolved dependency task dir + run spec (matches validate_dependency expansion).
# _pairs_ref: TASK_RUN_PAIRS-style array for wildcard merge with invocation (may be empty).
expand_dep_run_names() {
  local dep_task_dir="$1"
  local dep_run_spec="$2"
  local -n _ed_pairs_ref=$3
  local -n _ed_out_rn=$4
  _ed_out_rn=()
  if [[ -z "$dep_run_spec" ]]; then
    shopt -s nullglob
    local rf
    for rf in "$dep_task_dir"/*/; do
      [[ -d "$rf" ]] && _ed_out_rn+=("$(basename "$rf")")
    done
    shopt -u nullglob
  elif _has_wildcard_outside_braces "$dep_run_spec"; then
    local -a matched_runs=()
    expand_run_spec_for_clean "$dep_task_dir" "$dep_run_spec" matched_runs
    declare -A _matched_set=()
    local _mr
    for _mr in "${matched_runs[@]}"; do _matched_set["$_mr"]=1; done
    local _inv_pair _inv_td _inv_rn
    for _inv_pair in "${_ed_pairs_ref[@]}"; do
      _inv_td="${_inv_pair%%	*}"
      _inv_rn="${_inv_pair#*	}"
      if [[ "$_inv_td" == "$dep_task_dir" ]] && [[ "$_inv_rn" == $dep_run_spec ]] \
         && [[ -z "${_matched_set["$_inv_rn"]+x}" ]]; then
        matched_runs+=("$_inv_rn")
        _matched_set["$_inv_rn"]=1
      fi
    done
    _ed_out_rn=("${matched_runs[@]}")
  else
    expand_run_spec "$dep_run_spec" _ed_out_rn
  fi
}

# Absolute paths to dependency run folders for (task_dir, run_name), deduped (single expansion source).
collect_dep_run_abs_paths_for_task_run() {
  local task_dir="$1"
  local run_name="$2"
  local -n _cd_pairs_ref=$3
  local -n _cd_out_abs=$4
  _cd_out_abs=()
  declare -A _cd_seen_abs=()
  local dep_entries=()
  get_task_dependencies "$task_dir" "$run_name" dep_entries
  local dep_entry parsed dep_task_path dep_run_spec r
  local -a dep_run_names=()
  for dep_entry in "${dep_entries[@]}"; do
    set -f
    parsed=($(parse_task_spec "$dep_entry"))
    set +f
    dep_task_path="${parsed[0]}"
    dep_run_spec="${parsed[1]:-}"
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      dep_run_names=()
      expand_dep_run_names "$r" "$dep_run_spec" _cd_pairs_ref dep_run_names
      local rn
      for rn in "${dep_run_names[@]}"; do
        local abs_path="$r/$rn"
        [[ -n "${_cd_seen_abs[$abs_path]+x}" ]] && continue
        _cd_seen_abs["$abs_path"]=1
        _cd_out_abs+=("$abs_path")
      done
    done < <(resolve_arg "$dep_task_path")
  done
}

# Exit 1 if git reports porcelain under ASSETS or any dependency run path for this pair (--no-uncommitted-changes).
assert_scoped_git_clean_for_task_run_pair() {
  local task_dir="$1" run_name="$2"
  local -n _ag_pairs_ref=$3
  local root="${REPOSITORY_ROOT:?}"
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local assets_rel
  assets_rel=$(_repo_rel_from_abs "$ASSETS") || return 1
  local -a dep_abs=()
  collect_dep_run_abs_paths_for_task_run "$task_dir" "$run_name" _ag_pairs_ref dep_abs
  declare -A rel_seen=()
  rel_seen["$assets_rel"]=1
  local -a all_rels=("$assets_rel")
  local d_abs d_rel
  for d_abs in "${dep_abs[@]}"; do
    d_rel=$(_repo_rel_from_abs "$d_abs") || continue
    [[ -n "${rel_seen[$d_rel]+x}" ]] && continue
    rel_seen["$d_rel"]=1
    all_rels+=("$d_rel")
  done
  local por
  por="$(git -C "$root" status --porcelain -- "${all_rels[@]}" 2>/dev/null || true)"
  if [[ -n "$por" ]]; then
    echo "Error: --no-uncommitted-changes: uncommitted changes under ASSETS and/or dependency run paths; refusing to run." >&2
    exit 1
  fi
}

# Exit 1 if any task run in the invocation would see dirty ASSETS or dependency paths (--no-uncommitted-changes).
assert_scoped_git_clean_for_full_invocation() {
  local root="${REPOSITORY_ROOT:?}"
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local assets_rel
  assets_rel=$(_repo_rel_from_abs "$ASSETS") || return 1
  declare -A rel_seen=()
  rel_seen["$assets_rel"]=1
  local -a all_rels=("$assets_rel")
  local i td rn ov_tsv dep_abs d_abs d_rel
  local -a dep_abs=()
  for ((i = 0; i < ${#TASK_RUN_PAIRS[@]}; i++)); do
    ENV_OVERRIDES=()
    ov_tsv="${TASK_RUN_PAIR_OVERRIDES[$i]:-}"
    if [[ -n "$ov_tsv" ]]; then
      IFS=$'\t' read -ra ENV_OVERRIDES <<< "$ov_tsv"
    fi
    td="${TASK_RUN_PAIRS[$i]%%	*}"
    rn="${TASK_RUN_PAIRS[$i]#*	}"
    dep_abs=()
    collect_dep_run_abs_paths_for_task_run "$td" "$rn" TASK_RUN_PAIRS dep_abs
    for d_abs in "${dep_abs[@]}"; do
      d_rel=$(_repo_rel_from_abs "$d_abs") || continue
      [[ -n "${rel_seen[$d_rel]+x}" ]] && continue
      rel_seen["$d_rel"]=1
      all_rels+=("$d_rel")
    done
  done
  local por
  por="$(git -C "$root" status --porcelain -- "${all_rels[@]}" 2>/dev/null || true)"
  if [[ -n "$por" ]]; then
    echo "Error: --no-uncommitted-changes: uncommitted changes under ASSETS and/or dependency run paths before invocation; refusing to run." >&2
    exit 1
  fi
}

# Validate a single dependency (dependent occ_key depends on dep_task_dir with dep_run_spec).
# Updates _missing_deps, _missing_count_ref, and _dep_checks. Used by compute_stages.
# _dep_checks is keyed by occ_key (the dependent).
validate_dependency() {
  local occ_key="$1"
  local dep_task_dir="$2"
  local dep_run_spec="$3"
  local -n _inv_pair_set=$4
  local -n _inv_task_set=$5
  local -n _pairs_ref=$6
  local -n _missing_deps=$7
  local -n _missing_count_ref=$8
  local -n _dep_checks=$9
  local -n _unsatisfied_occ=${10}
  local task_dir="${occ_key%	OCC:*}"
  local dep_in_invocation=false
  [[ -n "${_inv_task_set["$dep_task_dir"]+x}" ]] && dep_in_invocation=true

  local -a dep_run_names=()
  expand_dep_run_names "$dep_task_dir" "$dep_run_spec" _pairs_ref dep_run_names

  if [[ -z "$dep_run_spec" ]]; then
    local all_disk_ok=true
    local rn
    for rn in "${dep_run_names[@]}"; do
      if [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; then
        all_disk_ok=false
        break
      fi
    done

    local has_at_least_one=false
    [[ -n "${_inv_task_set["$dep_task_dir"]+x}" ]] && has_at_least_one=true
    [[ ${#dep_run_names[@]} -gt 0 ]] && has_at_least_one=true

    local resolved_ok=false
    [[ "$all_disk_ok" == true ]] && [[ "$has_at_least_one" == true ]] && resolved_ok=true

    if [[ "$IGNORE_DEPS" == true && "$dep_in_invocation" != true ]]; then
      :
    elif [[ "$INCLUDE_DEPS" == true ]]; then
      if [[ -z "${_inv_task_set["$dep_task_dir"]+x}" ]]; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        _missing_deps["tasks/$rel_dep"]="${_missing_deps["tasks/$rel_dep"]:+${_missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
        _missing_count_ref=$((_missing_count_ref + 1))
      fi
    else
      if [[ "$resolved_ok" != true ]]; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        if [[ "$SKIP_UNSATISFIED_DEPS" == true ]] && [[ "$INCLUDE_DEPS" != true ]]; then
          _unsatisfied_occ["$occ_key"]=1
        else
          _missing_deps["tasks/$rel_dep"]="${_missing_deps["tasks/$rel_dep"]:+${_missing_deps["tasks/$rel_dep"]}, }tasks/$rel_task"
          _missing_count_ref=$((_missing_count_ref + 1))
        fi
      fi
    fi
    if [[ "$dep_in_invocation" == true ]]; then
      _dep_checks["$occ_key"]+="ALL	$dep_task_dir"$'\n'
    fi

  elif _has_wildcard_outside_braces "$dep_run_spec"; then
    if [[ ${#dep_run_names[@]} -eq 0 ]]; then
      if [[ "$IGNORE_DEPS" == true && "$dep_in_invocation" != true ]]; then
        return
      fi
      local rel_task="${task_dir#$TASKS/}"
      local rel_dep="${dep_task_dir#$TASKS/}"
      local dep_label="tasks/$rel_dep:$dep_run_spec (no matching run folders on disk)"
      if [[ "$SKIP_UNSATISFIED_DEPS" == true ]] && [[ "$INCLUDE_DEPS" != true ]]; then
        _unsatisfied_occ["$occ_key"]=1
      else
        _missing_deps["$dep_label"]="${_missing_deps["$dep_label"]:+${_missing_deps["$dep_label"]}, }tasks/$rel_task"
        _missing_count_ref=$((_missing_count_ref + 1))
      fi
    else
      local rn
      for rn in "${dep_run_names[@]}"; do
        if [[ "$IGNORE_DEPS" == true && "$dep_in_invocation" != true ]]; then
          :
        elif [[ -z "${_inv_pair_set["$dep_task_dir	$rn"]+x}" ]] && { [[ "$INCLUDE_DEPS" == true ]] || [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; }; then
          local rel_task="${task_dir#$TASKS/}"
          local rel_dep="${dep_task_dir#$TASKS/}"
          if [[ "$SKIP_UNSATISFIED_DEPS" == true ]] && [[ "$INCLUDE_DEPS" != true ]]; then
            _unsatisfied_occ["$occ_key"]=1
          else
            _missing_deps["tasks/$rel_dep:$rn"]="${_missing_deps["tasks/$rel_dep:$rn"]:+${_missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
            _missing_count_ref=$((_missing_count_ref + 1))
          fi
        fi
        if [[ "$dep_in_invocation" == true ]]; then
          _dep_checks["$occ_key"]+="RUN	$dep_task_dir	$rn"$'\n'
        fi
      done
    fi

  else
    local rn
    for rn in "${dep_run_names[@]}"; do
      if [[ "$IGNORE_DEPS" == true && "$dep_in_invocation" != true ]]; then
        :
      elif [[ -z "${_inv_pair_set["$dep_task_dir	$rn"]+x}" ]] && { [[ "$INCLUDE_DEPS" == true ]] || [[ ! -f "$dep_task_dir/$rn/.run_success" ]]; }; then
        local rel_task="${task_dir#$TASKS/}"
        local rel_dep="${dep_task_dir#$TASKS/}"
        if [[ "$SKIP_UNSATISFIED_DEPS" == true ]] && [[ "$INCLUDE_DEPS" != true ]]; then
          _unsatisfied_occ["$occ_key"]=1
        else
          _missing_deps["tasks/$rel_dep:$rn"]="${_missing_deps["tasks/$rel_dep:$rn"]:+${_missing_deps["tasks/$rel_dep:$rn"]}, }tasks/$rel_task"
          _missing_count_ref=$((_missing_count_ref + 1))
        fi
      fi
      if [[ "$dep_in_invocation" == true ]]; then
        _dep_checks["$occ_key"]+="RUN	$dep_task_dir	$rn"$'\n'
      fi
    done
  fi
}

# Compute stages from task dependencies. Populates _task_stage[occ_key]=stage_id.
# _tasks is TASK_OCC_KEYS (occurrence keys). Dependency on a task resolves to its last occurrence.
# Implicit sequential deps: same (task_dir, run_name) in consecutive pairs -> later stage.
compute_stages() {
  local -n _tasks=$1
  local -n _task_run_pairs_ref=$2
  local -n _task_stage=$3
  local -n _max_stage=$4
  local -n _task_dep_checks=$5
  _task_stage=()
  _task_dep_checks=()

  # Build invocation lookup: pair set, task set, and task_dir -> last occ_key (for dep resolution)
  declare -A invocation_pair_set
  declare -A invocation_task_set
  declare -A task_dir_to_last_occ
  declare -A pair_to_last_occ
  local i pair td rn occ_key
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    rn="${pair#*	}"
    invocation_pair_set["$td	$rn"]=1
    invocation_task_set["$td"]=1
    task_dir_to_last_occ["$td"]="$occ_key"
    pair_to_last_occ["$td	$rn"]="$occ_key"
  done

  declare -A deps
  declare -A dep_edges_added
  declare -A missing_deps
  declare -A unsatisfied_occ=()
  local missing_count=0
  local dep_entry

  # Initialize deps for all occurrence keys (newline-separated to preserve occ_key with tab)
  for occ_key in "${_tasks[@]}"; do
    deps["$occ_key"]=""
  done

  # Implicit sequential deps: same (task_dir, run_name) in consecutive pairs
  declare -A prev_occ_by_pair
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    rn="${pair#*	}"
    local pair_key="$td	$rn"
    if [[ -n "${prev_occ_by_pair[$pair_key]+x}" ]]; then
      local prev_occ="${prev_occ_by_pair[$pair_key]}"
      local edge_key="$prev_occ	$occ_key"
      if [[ -z "${dep_edges_added["$edge_key"]+x}" ]]; then
        deps["$occ_key"]+="${deps["$occ_key"]:+$'\n'}$prev_occ"
        dep_edges_added["$edge_key"]=1
      fi
    fi
    prev_occ_by_pair["$pair_key"]="$occ_key"
  done

  # Collect explicit deps per pair; dependency on task X -> edge to last occurrence of X
  # Use this pair's overrides when resolving deps so BUILD_FOLDER etc. are correct
  for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
    pair="${_task_run_pairs_ref[$i]}"
    occ_key="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
    td="${pair%%	*}"
    local run_name="${pair#*	}"
    ENV_OVERRIDES=()
    local ov_tsv="${TASK_RUN_PAIR_OVERRIDES[$i]:-}"
    if [[ -n "$ov_tsv" ]]; then
      IFS=$'\t' read -ra ENV_OVERRIDES <<< "$ov_tsv"
    fi
    local dep_entries=()
    get_task_dependencies "$td" "$run_name" dep_entries
    for dep_entry in "${dep_entries[@]}"; do
      local parsed
      set -f
      parsed=($(parse_task_spec "$dep_entry"))
      set +f
      local dep_task_path="${parsed[0]}"
      local dep_run_spec="${parsed[1]:-}"
      local resolved=() r
      while IFS= read -r r; do
        [[ -n "$r" ]] && resolved+=("$r")
      done < <(resolve_arg "$dep_task_path")

      for r in "${resolved[@]}"; do
        validate_dependency "$occ_key" "$r" "$dep_run_spec" \
          invocation_pair_set invocation_task_set _task_run_pairs_ref \
          missing_deps missing_count _task_dep_checks unsatisfied_occ
        [[ -z "${invocation_task_set["$r"]+x}" ]] && continue
        if [[ -z "$dep_run_spec" ]]; then
          local dep_occ="${task_dir_to_last_occ["$r"]}"
          local edge_key="$occ_key	$dep_occ"
          if [[ -z "${dep_edges_added["$edge_key"]+x}" ]] && [[ "$occ_key" != "$dep_occ" ]]; then
            deps["$occ_key"]+="${deps["$occ_key"]:+$'\n'}$dep_occ"
            dep_edges_added["$edge_key"]=1
          fi
        else
          local -a dep_runs=()
          expand_dep_run_names "$r" "$dep_run_spec" _task_run_pairs_ref dep_runs
          local dep_rn dep_occ
          for dep_rn in "${dep_runs[@]}"; do
            dep_occ="${pair_to_last_occ["$r	$dep_rn"]:-}"
            [[ -z "$dep_occ" ]] && continue
            local edge_key="$occ_key	$dep_occ"
            if [[ -z "${dep_edges_added["$edge_key"]+x}" ]] && [[ "$occ_key" != "$dep_occ" ]]; then
              deps["$occ_key"]+="${deps["$occ_key"]:+$'\n'}$dep_occ"
              dep_edges_added["$edge_key"]=1
            fi
          done
        fi
      done
    done
  done

  if [[ "$SKIP_UNSATISFIED_DEPS" == true ]] && [[ "$INCLUDE_DEPS" != true ]]; then
    local changed=true
    while [[ "$changed" == true ]]; do
      changed=false
      for occ_key in "${_tasks[@]}"; do
        [[ -n "${unsatisfied_occ["$occ_key"]+x}" ]] && continue
        local dep
        while IFS= read -r dep; do
          [[ -z "$dep" ]] && continue
          if [[ -n "${unsatisfied_occ["$dep"]+x}" ]]; then
            unsatisfied_occ["$occ_key"]=1
            changed=true
            break
          fi
        done <<< "${deps["$occ_key"]}"
      done
    done

    if [[ ${#unsatisfied_occ[@]} -gt 0 ]]; then
      local -a kept_tasks=()
      local -a kept_pairs=()
      local -a kept_occ_keys=()
      local -a kept_overrides=()
      local -a kept_wm=()
      local -a kept_wname=()
      local i pair_occ
      for ((i=0; i<${#_task_run_pairs_ref[@]}; i++)); do
        pair_occ="${TASK_RUN_PAIR_OCC_KEYS[$i]:-}"
        if [[ -n "${unsatisfied_occ["$pair_occ"]+x}" ]]; then
          continue
        fi
        kept_pairs+=("${_task_run_pairs_ref[$i]}")
        kept_occ_keys+=("$pair_occ")
        kept_overrides+=("${TASK_RUN_PAIR_OVERRIDES[$i]:-}")
        kept_wm+=("${TASK_RUN_PAIR_WM[$i]:-}")
        kept_wname+=("${TASK_RUN_PAIR_WORKLOAD_NAME[$i]:-}")
      done
      for occ_key in "${_tasks[@]}"; do
        [[ -n "${unsatisfied_occ["$occ_key"]+x}" ]] && continue
        kept_tasks+=("$occ_key")
      done
      _tasks=("${kept_tasks[@]}")
      _task_run_pairs_ref=("${kept_pairs[@]}")
      TASK_RUN_PAIR_OCC_KEYS=("${kept_occ_keys[@]}")
      TASK_RUN_PAIR_OVERRIDES=("${kept_overrides[@]}")
      TASK_RUN_PAIR_WM=("${kept_wm[@]}")
      TASK_RUN_PAIR_WORKLOAD_NAME=("${kept_wname[@]}")
    fi
  fi

  if [[ $missing_count -gt 0 ]]; then
    if [[ "$INCLUDE_DEPS" == true ]]; then
      RUN_TASKS_MISSING_SPECS=()
      for dep in "${!missing_deps[@]}"; do
        local spec
        if [[ "$dep" == *" (no matching run folders on disk)" ]]; then
          spec="${dep%%:*}"
        else
          spec="${dep% (no matching run folders on disk)}"
        fi
        RUN_TASKS_MISSING_SPECS+=("$spec")
      done
      return 1
    fi
    echo "Error: The following dependencies are neither in the current invocation nor satisfied on disk:" >&2
    for dep in "${!missing_deps[@]}"; do
      echo "  - $dep" >&2
      echo "    required by:" >&2
      local req
      for req in $(echo "${missing_deps[$dep]}" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u); do
        [[ -n "$req" ]] && echo "      - $req" >&2
      done
    done
    echo "" >&2
    echo "Include these dependency runs in your invocation or run them first." >&2
    exit 1
  fi

  # Topological sort (Kahn's algorithm) on occurrence keys (deps are newline-separated)
  declare -A in_degree
  for occ_key in "${_tasks[@]}"; do
    in_degree["$occ_key"]=0
  done
  for occ_key in "${_tasks[@]}"; do
    local dep
    while IFS= read -r dep; do
      [[ -n "$dep" ]] && in_degree["$occ_key"]=$((${in_degree["$occ_key"]} + 1))
    done <<< "${deps["$occ_key"]}"
  done

  local stage=0
  local remaining=("${_tasks[@]}")
  while [[ ${#remaining[@]} -gt 0 ]]; do
    local ready=()
    for occ_key in "${remaining[@]}"; do
      if [[ ${in_degree["$occ_key"]} -eq 0 ]]; then
        ready+=("$occ_key")
      fi
    done
    if [[ ${#ready[@]} -eq 0 ]]; then
      echo "Error: Circular dependency detected among tasks." >&2
      exit 1
    fi
    for occ_key in "${ready[@]}"; do
      _task_stage["$occ_key"]=$stage
    done
    for occ_key in "${remaining[@]}"; do
      local dep
      while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        for ready_occ in "${ready[@]}"; do
          if [[ "$dep" == "$ready_occ" ]]; then
            in_degree["$occ_key"]=$((${in_degree["$occ_key"]} - 1))
            break
          fi
        done
      done <<< "${deps["$occ_key"]}"
    done
    local new_remaining=()
    for occ_key in "${remaining[@]}"; do
      local is_ready=false
      for r in "${ready[@]}"; do
        [[ "$occ_key" == "$r" ]] && { is_ready=true; break; }
      done
      [[ "$is_ready" != true ]] && new_remaining+=("$occ_key")
    done
    remaining=("${new_remaining[@]}")
    stage=$((stage + 1))
  done
  _max_stage=$((stage - 1))
}

# Verify that all dependency runs for tasks in a given stage have .run_success files.
# _csd_tasks is TASK_OCC_KEYS; _csd_task_stage and _csd_dep_checks are keyed by occ_key.
check_stage_deps() {
  local stage=$1
  local -n _csd_tasks=$2
  local -n _csd_task_stage=$3
  local -n _csd_dep_checks=$4
  local -n _csd_task_run_pairs=$5

  local -a unsatisfied=()
  local occ_key
  for occ_key in "${_csd_tasks[@]}"; do
    [[ "${_csd_task_stage[$occ_key]:--1}" != "$stage" ]] && continue
    local checks="${_csd_dep_checks[$occ_key]:-}"
    [[ -z "$checks" ]] && continue
    while IFS= read -r check; do
      [[ -z "$check" ]] && continue
      local check_type rest dep_dir dep_run
      check_type="${check%%	*}"
      rest="${check#*	}"
      if [[ "$check_type" == "ALL" ]]; then
        dep_dir="$rest"
        local -a disk_runs=()
        shopt -s nullglob
        local rf
        for rf in "$dep_dir"/*/; do
          [[ -d "$rf" ]] && disk_runs+=("$(basename "$rf")")
        done
        shopt -u nullglob

        local -A union_runs=()
        local rn
        for rn in "${disk_runs[@]}"; do
          union_runs["$rn"]=1
        done
        local pair td rn_val
        for pair in "${_csd_task_run_pairs[@]}"; do
          td="${pair%%	*}"
          rn_val="${pair#*	}"
          [[ "$td" == "$dep_dir" ]] && union_runs["$rn_val"]=1
        done

        if [[ ${#union_runs[@]} -eq 0 ]]; then
          local rel_dep="${dep_dir#$TASKS/}"
          local task_dir="${occ_key%	OCC:*}"
          local rel_task="${task_dir#$TASKS/}"
          unsatisfied+=("tasks/$rel_dep (at least one run required) required by tasks/$rel_task")
        else
          for rn in "${!union_runs[@]}"; do
            if [[ ! -f "$dep_dir/$rn/.run_success" ]]; then
              local rel_dep="${dep_dir#$TASKS/}"
              local task_dir="${occ_key%	OCC:*}"
              local rel_task="${task_dir#$TASKS/}"
              unsatisfied+=("tasks/$rel_dep/$rn required by tasks/$rel_task")
            fi
          done
        fi
      elif [[ "$check_type" == "RUN" ]]; then
        dep_dir="${rest%%	*}"
        dep_run="${rest#*	}"
        if [[ ! -f "$dep_dir/$dep_run/.run_success" ]]; then
          local rel_dep="${dep_dir#$TASKS/}"
          local task_dir="${occ_key%	OCC:*}"
          local rel_task="${task_dir#$TASKS/}"
          unsatisfied+=("tasks/$rel_dep/$dep_run required by tasks/$rel_task")
        fi
      fi
    done <<< "$checks"
  done

  if [[ ${#unsatisfied[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Error: Unsatisfied dependencies before stage $stage:" >&2
    for u in "${unsatisfied[@]}"; do
      echo "  - $u" >&2
    done
    exit 1
  fi
}
