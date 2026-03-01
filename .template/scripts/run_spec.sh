#!/usr/bin/env bash
# Run spec expansion and task status.
#
# RUN_SPECS format (same for execute, clean, and dependency specs): comma-separated
# list of RUN_SPEC items. Splitting respects braces: only commas outside {...} split.
# Each RUN_SPEC is a literal with zero or more expansion patterns:
#   {a,b,c}       -> list (comma-separated, trim spaces)
#   {start:end}   -> integer range (inclusive). If start > end, no values.
# Multiple patterns in one RUN_SPEC expand to the cartesian product (inverse order
# of occurrence: first pattern varies slowest, last fastest).
# For clean mode and dependency specs, wildcards * and ? outside {...} are also
# supported and match existing run folders or run names.

# Check if a task run has already succeeded (has .run_success file).
is_task_succeeded() {
  local task_dir="$1"
  local run_name="$2"
  [[ -f "$task_dir/$run_name/.run_success" ]]
}

# Split RUN_SPECS string into RUN_SPEC tokens (comma at depth 0 only). Skip empty. Append to _out.
_split_run_specs() {
  local spec="$1"
  local -n _out=$2
  local depth=0 token="" i c
  for ((i=0; i<${#spec}; i++)); do
    c="${spec:i:1}"
    if [[ "$c" == "{" ]]; then
      ((depth++)) || true
      token+="$c"
    elif [[ "$c" == "}" ]]; then
      ((depth--)) || true
      token+="$c"
    elif [[ "$c" == "," ]] && [[ $depth -eq 0 ]]; then
      token="${token#"${token%%[![:space:]]*}"}"
      token="${token%"${token##*[![:space:]]}"}"
      [[ -n "$token" ]] && _out+=("$token")
      token=""
    else
      token+="$c"
    fi
  done
  token="${token#"${token%%[![:space:]]*}"}"
  token="${token%"${token##*[![:space:]]}"}"
  [[ -n "$token" ]] && _out+=("$token")
}

# Expand one RUN_SPEC (may contain patterns) and append run names to _out.
_expand_one_run_spec() {
  local spec="$1"
  local -n _out=$2
  local template="" pattern_contents=()
  local spec_len=${#spec} i=0 pidx=0

  # Parse all {...} patterns (non-nested) and build template with placeholders.
  while ((i < spec_len)); do
    if [[ "${spec:i:1}" == "{" ]]; then
      local j=$((i + 1))
      while ((j < spec_len)) && [[ "${spec:j:1}" != "}" ]]; do
        ((j++)) || true
      done
      if ((j < spec_len)); then
        local content="${spec:i+1:j-i-1}"
        pattern_contents+=("$content")
        # Unique placeholder char per pattern: \x01, \x02, ...
        local ph
        printf -v ph '%b' "\\x$(printf '%02x' $((pidx + 1)))"
        template+="$ph"
        ((pidx++)) || true
        i=$((j + 1))
        continue
      fi
    fi
    template+="${spec:i:1}"
    ((i++)) || true
  done

  local npat=${#pattern_contents[@]}
  if ((npat == 0)); then
    [[ -n "$template" ]] && _out+=("$template")
    return
  fi

  # Build value list for each pattern. Join with US so values can contain spaces.
  local -a pattern_values
  local pidx sep=$'\037'
  for ((pidx=0; pidx<npat; pidx++)); do
    local content="${pattern_contents[pidx]}"
    local -a vals=()
    if [[ "$content" =~ ^([0-9]+):([0-9]+)$ ]]; then
      local start="${BASH_REMATCH[1]}"
      local end="${BASH_REMATCH[2]}"
      if [[ "$start" -le "$end" ]]; then
        local ii
        for ((ii=start; ii<=end; ii++)); do
          vals+=("$ii")
        done
      fi
    else
      local old_ifs="$IFS"
      IFS=,
      local v
      for v in $content; do
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        [[ -n "$v" ]] && vals+=("$v")
      done
      IFS="$old_ifs"
    fi
    local IFS="$sep"
    pattern_values+=("${vals[*]}")
  done

  # Cartesian product (first pattern varies slowest, last fastest).
  local -a stack_indices=()
  local -a stack_max=()
  local p
  for ((p=0; p<npat; p++)); do
    local -a varr=()
    IFS="$sep" read -ra varr <<< "${pattern_values[p]}"
    stack_max+=("${#varr[@]}")
  done

  # If any pattern has zero values, product is empty.
  local empty=0
  for ((p=0; p<npat; p++)); do
    [[ ${stack_max[p]} -eq 0 ]] && empty=1 && break
  done
  [[ $empty -eq 1 ]] && return

  for ((p=0; p<npat; p++)); do stack_indices+=(0); done

  while true; do
    local run_name="$template"
    local -a varr
    for ((p=0; p<npat; p++)); do
      IFS="$sep" read -ra varr <<< "${pattern_values[p]}"
      local val="${varr[stack_indices[p]]}"
      local ph
      printf -v ph '%b' "\\x$(printf '%02x' $((p + 1)))"
      run_name="${run_name//$ph/$val}"
    done
    _out+=("$run_name")

    # Increment (last index varies fastest).
    local carry=1
    for ((p=npat-1; p>=0 && carry; p--)); do
      local next=$((${stack_indices[p]} + 1))
      if [[ $next -lt ${stack_max[p]} ]]; then
        stack_indices[p]=$next
        carry=0
      else
        stack_indices[p]=0
      fi
    done
    [[ $carry -eq 1 ]] && break
  done
}

# Expand RUN_SPECS to array of run names. RUN_SPECS is comma-separated (split at depth 0).
# Each RUN_SPEC can contain {a,b,c} and {start:end}; multiple patterns -> cartesian product.
expand_run_spec() {
  local spec="$1"
  local -n _out=$2
  _out=()
  local -a tokens=()
  _split_run_specs "$spec" tokens
  local t
  for t in "${tokens[@]}"; do
    _expand_one_run_spec "$t" "$2"
  done
}

# Returns 1 if spec has * or ? outside of {...}, 0 otherwise.
_has_wildcard_outside_braces() {
  local spec="$1"
  local depth=0 i c
  for ((i=0; i<${#spec}; i++)); do
    c="${spec:i:1}"
    if [[ "$c" == "{" ]]; then
      ((depth++)) || true
    elif [[ "$c" == "}" ]]; then
      ((depth--)) || true
    elif [[ $depth -eq 0 ]] && { [[ "$c" == "*" ]] || [[ "$c" == "?" ]]; }; then
      return 0
    fi
  done
  return 1
}

# For clean mode: same RUN_SPECS format; if * or ? outside {...}, match existing run folders.
expand_run_spec_for_clean() {
  local task_dir="$1"
  local spec="$2"
  local -n _out=$3
  _out=()
  if _has_wildcard_outside_braces "$spec"; then
    shopt -s nullglob
    local run_folder
    for run_folder in "$task_dir"/*/; do
      [[ -d "$run_folder" ]] || continue
      is_run_folder "$run_folder" || continue
      local run_name
      run_name=$(basename "$run_folder")
      [[ "$run_name" == $spec ]] && _out+=("$run_name")
    done
    shopt -u nullglob
    local -a sorted=()
    local _run
    while IFS= read -r _run; do
      [[ -n "$_run" ]] && sorted+=("$_run")
    done < <(printf '%s\n' "${_out[@]}" | sort)
    _out=("${sorted[@]}")
  else
    local -a tmp_runs=()
    expand_run_spec "$spec" tmp_runs
    _out=("${tmp_runs[@]}")
  fi
}
