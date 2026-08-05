#!/usr/bin/env bash
# Task-run resolution and building task-run pairs.

# True if dir is a run folder (has framework marker files). Used to exclude run output from task resolution.
is_run_folder() {
  local dir="$1"
  [[ -f "$dir/.run_script.sh" || -f "$dir/.run_begin" || -f "$dir/.run_success" || -f "$dir/.run_failed" || -f "$dir/.run_metadata" ]]
}

# Resolves a single argument to a list of absolute task directory paths.
# Resolves relative paths against the current working directory; validates that
# results are located under the injected $TASKS root.
resolve_arg() {
  local arg="$1"
  local resolved=()

  local tasks_root_abs
  tasks_root_abs="$(cd "$TASKS" 2>/dev/null && pwd)" || { echo "Error: TASKS not found: $TASKS" >&2; exit 1; }

  # Handle wildcards: expand glob and filter to dirs with run.sh
    # (* and ? = standard glob; ** = recursive globstar; !( = extglob exclusion)
    # Note: arg comes from user-controlled run_deps.sh; glob chars (*?!) are safe.
    if [[ "$arg" == *"*"* || "$arg" == *"?"* || "$arg" == *"!("* ]]; then
    # Reject shell metacharacters that could enable injection in eval. Allow () for extglob !(pattern).
    case "$arg" in
      *';'*|*'|'*|*'&'*|*'`'*|*'$'*)
        echo "Error: Path contains invalid characters: $arg" >&2
        exit 1
        ;;
    esac
    local extglob_was_set=0 globstar_was_set=0
    shopt -q extglob && extglob_was_set=1
    shopt -q globstar && globstar_was_set=1
    shopt -s extglob globstar  # enable !(pattern) and ** recursive matching
    local expanded path abs
    expanded=($(eval "ls -d $arg" 2>/dev/null || true))
    if [[ "$extglob_was_set" -eq 0 ]]; then shopt -u extglob; fi
    if [[ "$globstar_was_set" -eq 0 ]]; then shopt -u globstar; fi
    for path in "${expanded[@]}"; do
      [[ -d "$path" && -f "$path/run.sh" ]] || continue
      is_run_folder "$path" && continue
      abs="$(cd "$path" && pwd)"
      [[ "$abs" == "$tasks_root_abs"* ]] && resolved+=("$abs")
    done
  else
    [[ ! -e "$arg" ]] && { echo "Error: Path does not exist: $arg" >&2; exit 1; }
    # Skip files (e.g. env.sh when glob expands data1/*)
    [[ -f "$arg" ]] && return 0
    [[ ! -d "$arg" ]] && { echo "Error: Not a directory: $arg" >&2; exit 1; }
    local abs_path
    abs_path="$(cd "$arg" && pwd)"
    if [[ "$abs_path" != "$tasks_root_abs"* ]]; then
      echo "Error: Task must be under tasks/: $arg" >&2
      exit 1
    fi
    if [[ -f "$abs_path/run.sh" ]] && ! is_run_folder "$abs_path"; then
      resolved+=("$abs_path")
    else
      # Parent directory: find all descendant dirs with run.sh, excluding run folders
      local dir
      while IFS= read -r -d '' path; do
        dir="$(cd "$(dirname "$path")" && pwd)"
        is_run_folder "$dir" || resolved+=("$dir")
      done < <(find "$abs_path" -name "run.sh" -type f -print0 2>/dev/null)
      if [[ ${#resolved[@]} -eq 0 ]]; then
        echo "Error: No tasks found under $arg (no run.sh in descendents)" >&2
        exit 1
      fi
    fi
  fi

  printf '%s\n' "${resolved[@]}"
}

# Resolves a single --exclude path argument to absolute task directory paths.
# For wildcard args, this treats matched directories as subtree anchors, so
# patterns like tasks/**/my_tasks can exclude descendant tasks even when the
# matched directory itself has no run.sh.
resolve_exclude_arg() {
  local arg="$1"

  # Non-wildcard path behavior is identical to normal resolution.
  if [[ "$arg" != *"*"* && "$arg" != *"?"* && "$arg" != *"!("* ]]; then
    resolve_arg "$arg"
    return
  fi

  # Reject shell metacharacters that could enable injection in eval.
  case "$arg" in
    *';'*|*'|'*|*'&'*|*'`'*|*'$'*)
      echo "Error: Path contains invalid characters: $arg" >&2
      exit 1
      ;;
  esac

  local extglob_was_set=0 globstar_was_set=0
  shopt -q extglob && extglob_was_set=1
  shopt -q globstar && globstar_was_set=1
  shopt -s extglob globstar
  local expanded=()
  expanded=($(eval "ls -d $arg" 2>/dev/null || true))
  if [[ "$extglob_was_set" -eq 0 ]]; then shopt -u extglob; fi
  if [[ "$globstar_was_set" -eq 0 ]]; then shopt -u globstar; fi

  local path
  for path in "${expanded[@]}"; do
    [[ -d "$path" ]] || continue
    resolve_arg "$path"
  done
}

# Reduce tab-separated KEY=VALUE list to final value per key (last occurrence wins).
# Output: tab-separated KEY=VALUE (order = last occurrence of each key).
reduce_override_to_final_per_key() {
  local tsv="$1"
  if [[ -z "$tsv" ]]; then
    return
  fi
  local -a parts=()
  IFS=$'\t' read -ra parts <<< "$tsv"
  declare -A ov=()
  local -a out_keys=()
  local p key
  for p in "${parts[@]}"; do
    [[ "$p" != *=* ]] && continue
    key="${p%%=*}"
    ov["$key"]="${p#*=}"
    # Keep order of last occurrence: remove key if present, then append
    local -a new_order=()
    local k
    for k in "${out_keys[@]}"; do
      [[ "$k" != "$key" ]] && new_order+=("$k")
    done
    out_keys=("${new_order[@]}" "$key")
  done
  local i=0
  for key in "${out_keys[@]}"; do
    [[ -z "${ov[$key]+x}" ]] && continue
    [[ $i -gt 0 ]] && printf '\t'
    printf '%s=%s' "$key" "${ov[$key]}"
    ((i++)) || true
  done
}

# FD used for BASH_XTRACEFD during --trace-discovery (avoid 0-2 and common redirects).
DISCOVERY_XTRACE_FD=77

# Start timestamped xtrace of discovery into TRACE_DISCOVERY_FILE (or a default under workload_logs/).
start_discovery_xtrace() {
  local file="${TRACE_DISCOVERY_FILE:-}"
  if [[ -z "$file" ]]; then
    mkdir -p "$RUN_TASKS_OUTPUT_ROOT"
    file="$RUN_TASKS_OUTPUT_ROOT/discovery-xtrace.$$.log"
    TRACE_DISCOVERY_FILE="$file"
  else
    local dir
    dir="$(dirname -- "$file")"
    [[ "$dir" == "." ]] || mkdir -p "$dir"
  fi
  eval "exec ${DISCOVERY_XTRACE_FD}>>\"\$file\""
  export BASH_XTRACEFD=$DISCOVERY_XTRACE_FD
  # GNU date %N; evaluated per traced line (not itself traced).
  PS4='+ $(date +%s.%N) ${BASH_SOURCE[0]}:${LINENO}:${FUNCNAME[0]:-main}: '
  {
    echo "=== discovery xtrace begin $(date -Iseconds) pid=$$ ==="
  } >&$DISCOVERY_XTRACE_FD
  echo "Tracing discovery to $file" >&2
  set -x
}

# Stop discovery xtrace, close the FD, and print a simple hotspot summary to stderr.
stop_discovery_xtrace() {
  set +x
  trap - RETURN
  unset BASH_XTRACEFD
  if { true >&$DISCOVERY_XTRACE_FD; } 2>/dev/null; then
    {
      echo "=== discovery xtrace end $(date -Iseconds) ==="
    } >&$DISCOVERY_XTRACE_FD
    eval "exec ${DISCOVERY_XTRACE_FD}>&-"
  fi
  local file="${TRACE_DISCOVERY_FILE:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  echo "Discovery xtrace written to $file" >&2
  echo "Top discovery hotspots (cumulative seconds, by source:line:func):" >&2
  awk '
    /^\++ [0-9]+\.[0-9]+ / {
      ts = $2
      loc = $3
      sub(/:$/, "", loc)
      if (prev_ts != "") {
        dt = ts - prev_ts
        if (dt < 0) dt = 0
        sum[prev_loc] += dt
        count[prev_loc]++
      }
      prev_ts = ts
      prev_loc = loc
      next
    }
    END {
      n = 0
      for (k in sum) {
        n++
        keys[n] = k
        vals[n] = sum[k]
      }
      for (i = 1; i <= n; i++) {
        for (j = i + 1; j <= n; j++) {
          if (vals[j] > vals[i]) {
            tmp = vals[i]; vals[i] = vals[j]; vals[j] = tmp
            tmpk = keys[i]; keys[i] = keys[j]; keys[j] = tmpk
          }
        }
      }
      limit = (n < 25) ? n : 25
      for (i = 1; i <= limit; i++) {
        printf "  %8.3f s  (%5d hits)  %s\n", vals[i], count[keys[i]], keys[i]
      }
    }
  ' "$file" >&2
}

# Build TASK_RUN_PAIRS, TASK_RUN_PAIR_OVERRIDES, TASK_RUN_PAIR_OCC_KEYS, TASK_OCC_KEYS, TASKS_UNIQUE from TASK_SPECS.
# Overrides are per-spec (TASK_SPEC_OVERRIDES). Same (task_dir, run_name, override_snapshot) = same occurrence group (OCC:N).
# Pairs are emitted in spec order; within each spec, run-first task-second order. Duplicate (task_dir, run_name) across specs allowed.
build_task_run_pairs() {
  if [[ "${TRACE_DISCOVERY:-false}" == true ]]; then
    start_discovery_xtrace
    trap 'stop_discovery_xtrace' RETURN
  fi

  clear_resolve_run_var_cache

  TASK_RUN_PAIRS=()
  TASK_RUN_PAIR_OVERRIDES=()
  TASK_RUN_PAIR_OCC_KEYS=()
  TASK_OCC_KEYS=()
  TASKS_UNIQUE=()
  declare -A occ_key_by_task_run_override=()
  local occ_counter=0
  local -a pairs_with_override=()
  local spec_idx=0

  for spec in "${TASK_SPECS[@]}"; do
    [[ -z "$spec" ]] && ((spec_idx++)) || true
    [[ -z "$spec" ]] && continue
    local spec_action="${TASK_SPEC_ACTIONS[$spec_idx]:-include}"
    local override_tsv="${TASK_SPEC_OVERRIDES[$spec_idx]:-}"
    if [[ "$spec_action" == "exclude" ]]; then
      local parsed
      set -f
      parsed=($(parse_task_spec "$spec"))
      set +f
      local task_path="${parsed[0]}"
      local run_spec="${parsed[1]:-}"
      declare -A excluded_tasks=()
      declare -A excluded_pairs=()
      local task_dir
      while IFS= read -r task_dir; do
        [[ -z "$task_dir" ]] && continue
        excluded_tasks["$task_dir"]=1
        if [[ -n "$run_spec" ]]; then
          local -a excluded_runs=()
          if [[ "$CLEAN" == true ]]; then
            expand_run_spec_for_clean "$task_dir" "$run_spec" excluded_runs
          else
            expand_run_spec "$run_spec" excluded_runs
          fi
          local r
          for r in "${excluded_runs[@]}"; do
            excluded_pairs["$task_dir	$r"]=1
          done
        fi
      done < <(resolve_exclude_arg "$task_path")

      local -a kept_pairs=()
      local pair_override
      for pair_override in "${pairs_with_override[@]}"; do
        local t="${pair_override%%	*}"
        local rest="${pair_override#*	}"
        local r="${rest%%	*}"
        if [[ -z "$run_spec" ]]; then
          local excluded_root
          for excluded_root in "${!excluded_tasks[@]}"; do
            if [[ "$t" == "$excluded_root" || "$t" == "$excluded_root"/* ]]; then
              continue 2
            fi
          done
        else
          [[ -n "${excluded_pairs["$t	$r"]+x}" ]] && continue
        fi
        kept_pairs+=("$pair_override")
      done
      pairs_with_override=("${kept_pairs[@]}")
      ((spec_idx++)) || true
      continue
    fi
    ENV_OVERRIDES=()
    if [[ -n "$override_tsv" ]]; then
      IFS=$'\t' read -ra ENV_OVERRIDES <<< "$override_tsv"
    fi
    local parsed
    set -f
    parsed=($(parse_task_spec "$spec"))
    set +f
    local task_path="${parsed[0]}"
    local run_spec="${parsed[1]:-}"

    local -a tasks_ordered=()
    declare -A task_runs=()

    while IFS= read -r task_dir; do
      [[ -z "$task_dir" ]] && continue
      if [[ "$task_dir" != "$TASKS"* ]]; then
        echo "Error: Task must be under tasks/: $task_dir" >&2
        exit 1
      fi
      if [[ ! -f "$task_dir/run.sh" ]]; then
        echo "Error: Not a task directory (no run.sh): $task_dir" >&2
        exit 1
      fi
      if is_run_folder "$task_dir"; then
        echo "Error: Not a task directory (is a run folder): $task_dir" >&2
        exit 1
      fi

      if [[ -z "${task_runs[$task_dir]+x}" ]]; then
        tasks_ordered+=("$task_dir")
      fi

      local -a runs=()
      if [[ -z "$run_spec" ]]; then
        if [[ "$CLEAN" == true ]]; then
          shopt -s nullglob
          local run_folder
          for run_folder in "$task_dir"/*/; do
            [[ -d "$run_folder" ]] || continue
            is_run_folder "$run_folder" || continue
            runs+=("$(basename "$run_folder")")
          done
          shopt -u nullglob
          local -a sorted=()
          while IFS= read -r r; do
            [[ -n "$r" ]] && sorted+=("$r")
          done < <(printf '%s\n' "${runs[@]}" | sort)
          runs=("${sorted[@]}")
        else
          # Unset TASK_RUNS -> default "assets"; set-but-empty -> no runs.
          local resolved_run_spec
          if [[ "$(resolve_task_var_isset "$task_dir" "TASK_RUNS")" == "1" ]]; then
            resolved_run_spec=$(resolve_task_var "$task_dir" "TASK_RUNS")
          else
            resolved_run_spec="assets"
          fi
          expand_run_spec "$resolved_run_spec" runs
        fi
      else
        if [[ "$CLEAN" == true ]]; then
          expand_run_spec_for_clean "$task_dir" "$run_spec" runs
        else
          expand_run_spec "$run_spec" runs
        fi
      fi

      local existing="${task_runs[$task_dir]:-}"
      for r in "${runs[@]}"; do
        existing="${existing:+$existing }$r"
      done
      task_runs["$task_dir"]="$existing"
      done < <(resolve_arg "$task_path")

    # Emit pairs for this spec in run-first, task-second order
    # Only add TASK_RUNS to overrides when explicitly from CLI: user-used suffix (spec_idx < ORIGINAL_TASK_SPEC_COUNT). Do not add for specs added by --include-deps or when TASK_RUNS comes from task_meta/default.
    local effective_ov_tsv="$override_tsv"
    if [[ -n "$run_spec" ]] && [[ "$spec_idx" -lt "${ORIGINAL_TASK_SPEC_COUNT:-0}" ]]; then
      effective_ov_tsv="${effective_ov_tsv:+${effective_ov_tsv}$'\t'}TASK_RUNS=$run_spec"
    fi
    local max_runs=0
    local t
    for t in "${tasks_ordered[@]}"; do
      local -a truns=()
      read -ra truns <<< "${task_runs[$t]:-}"
      [[ ${#truns[@]} -gt $max_runs ]] && max_runs=${#truns[@]}
    done
    # Reduce once per spec so cache keys match the pair-assignment loop below.
    local resolve_ov_tsv
    resolve_ov_tsv=$(reduce_override_to_final_per_key "$effective_ov_tsv")
    local run_idx
    for ((run_idx=0; run_idx < max_runs; run_idx++)); do
      for t in "${tasks_ordered[@]}"; do
        local -a truns=()
        read -ra truns <<< "${task_runs[$t]:-}"
        if [[ $run_idx -lt ${#truns[@]} ]]; then
          local run_name="${truns[$run_idx]}"
          ENV_OVERRIDES=()
          [[ -n "$resolve_ov_tsv" ]] && IFS=$'\t' read -ra ENV_OVERRIDES <<< "$resolve_ov_tsv"
          # One bash -c for DISABLED + WM + NAME (+isset); later lookups hit the cache.
          if [[ "$INCLUDE_DISABLED" != true ]]; then
            resolve_run_vars "$t" "$run_name" RUN_DISABLED RUN_WORKLOAD_MANAGER RUN_WORKLOAD_NAME
            local run_disabled
            run_disabled=$(printf '%s' "${RESOLVED_RUN_VARS[RUN_DISABLED]-}" | tr '[:upper:]' '[:lower:]')
            case "$run_disabled" in
              true|1|yes) continue ;;
            esac
          else
            resolve_run_vars "$t" "$run_name" RUN_WORKLOAD_MANAGER RUN_WORKLOAD_NAME
          fi
          pairs_with_override+=("$t	$run_name	$effective_ov_tsv")
        fi
      done
    done

    ((spec_idx++)) || true
  done

  # Assign occurrence keys and build output arrays
  TASK_RUN_PAIR_WM=()
  TASK_RUN_PAIR_WORKLOAD_NAME=()
  local pair_override
  for pair_override in "${pairs_with_override[@]}"; do
    local task_dir="${pair_override%%	*}"
    local rest="${pair_override#*	}"
    local run_name="${rest%%	*}"
    local ov_tsv="${rest#*	}"
    if [[ "$ov_tsv" == "$run_name" ]]; then
      ov_tsv=""
    fi

    local occ_key
    if [[ -z "${occ_key_by_task_run_override["$task_dir	$run_name	$ov_tsv"]+x}" ]]; then
      occ_key="$task_dir	OCC:$occ_counter"
      occ_key_by_task_run_override["$task_dir	$run_name	$ov_tsv"]="$occ_key"
      TASK_OCC_KEYS+=("$occ_key")
      ((occ_counter++)) || true
    else
      occ_key="${occ_key_by_task_run_override["$task_dir	$run_name	$ov_tsv"]}"
    fi

    local pair_ov_tsv
    pair_ov_tsv=$(reduce_override_to_final_per_key "$ov_tsv")
    TASK_RUN_PAIRS+=("$task_dir	$run_name")
    TASK_RUN_PAIR_OVERRIDES+=("$pair_ov_tsv")
    TASK_RUN_PAIR_OCC_KEYS+=("$occ_key")

    # Resolve RUN_WORKLOAD_MANAGER and RUN_WORKLOAD_NAME (cache hit after emit-loop batch)
    ENV_OVERRIDES=()
    [[ -n "$pair_ov_tsv" ]] && IFS=$'\t' read -ra ENV_OVERRIDES <<< "$pair_ov_tsv"
    resolve_run_vars "$task_dir" "$run_name" RUN_WORKLOAD_MANAGER RUN_WORKLOAD_NAME
    local wm workload_name
    wm="${RESOLVED_RUN_VARS[RUN_WORKLOAD_MANAGER]-}"
    [[ -z "$wm" ]] && wm="$TEMPLATE/workload_managers/direct.sh"
    if [[ "$wm" != /* ]]; then
      echo "Error: RUN_WORKLOAD_MANAGER must be an absolute path. Got: $wm" >&2
      exit 1
    fi
    workload_name="${RESOLVED_RUN_VARS[RUN_WORKLOAD_NAME]-}"
    # Default to run_tasks only when RUN_WORKLOAD_NAME is unset (neither in overrides nor run_meta.sh)
    if [[ -z "$workload_name" ]]; then
      if [[ "${RESOLVED_RUN_VARS_ISSET[RUN_WORKLOAD_NAME]-0}" == "1" ]]; then
        workload_name=""   # explicitly set to empty
      else
        workload_name="run_tasks"
      fi
    fi
    TASK_RUN_PAIR_WM+=("$wm")
    TASK_RUN_PAIR_WORKLOAD_NAME+=("$workload_name")
  done

  # TASKS_UNIQUE: unique task dirs for display (first occurrence order)
  declare -A seen_task=()
  for pair_override in "${pairs_with_override[@]}"; do
    local task_dir="${pair_override%%	*}"
    if [[ -z "${seen_task[$task_dir]+x}" ]]; then
      seen_task["$task_dir"]=1
      TASKS_UNIQUE+=("$task_dir")
    fi
  done
}
