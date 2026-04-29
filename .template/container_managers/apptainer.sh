#!/usr/bin/env bash
# Container manager for Apptainer (https://apptainer.org/).
# Interface: container_verify IMAGE_PATH DEF_PATH [DIFF_LOG], container_exec_snippet (echoes to stdout).
# Backends that do not support verification must exit with error from container_verify.

container_verify() {
  local image_path="$1"
  local def_path="$2"
  local diff_log="${3:-}"
  local normalize_def
  normalize_def() { sed -e 's/^[bB]ootstrap:/Bootstrap:/' -e 's/^[fF]rom:/From:/'; }
  local diff_out
  diff_out=$(mktemp)
  if ! diff <(apptainer inspect --deffile "$image_path" 2>/dev/null | normalize_def) <(normalize_def < "$def_path") > "$diff_out" 2>&1; then
    if [[ -n "$diff_log" ]]; then
      {
        echo "Container definition verification failed."
        echo "Comparing: embedded def in $image_path vs. $def_path"
        echo "---"
        cat "$diff_out"
      } > "$diff_log"
    fi
    rm -f "$diff_out"
    echo "Error: Container $image_path was not built from $def_path (definitions differ). Rebuild the image using the task's container definition and your chosen runtime. Use --skip-verify-def to run anyway." >&2
    [[ -n "$diff_log" ]] && echo "Diff written to $diff_log" >&2
    return 1
  fi
  rm -f "$diff_out"
  return 0
}

# Echo the shell fragment that re-execs into the container. Uses CONTAINER, CONTAINER_GPU,
# CONTAINER_FLAGS, REPOSITORY_ROOT from the environment (set by execution.sh when calling).
container_exec_snippet() {
  local repo_root="${REPOSITORY_ROOT:?}"
  echo '# If CONTAINER set and not already inside container, re-exec inside container'
  echo 'if [[ -z "${CONTAINER_INNER:-}" ]] && [[ -n "${CONTAINER:-}" ]]; then'
  echo '  userns_flag=""'
  echo '  gpu_flag=""'
  echo '  [[ -n "${CONTAINER_GPU:-}" ]] && gpu_flag="--nv "'
  echo "  if ! apptainer exec \${CONTAINER_FLAGS:-} \$gpu_flag -B \"$repo_root:$repo_root\" \"\$CONTAINER\" true >/dev/null 2>&1; then"
  echo "    if apptainer exec --userns \${CONTAINER_FLAGS:-} \$gpu_flag -B \"$repo_root:$repo_root\" \"\$CONTAINER\" true >/dev/null 2>&1; then"
  echo '        userns_flag="--userns "'
  echo '    fi'
  echo '  fi'
  echo "  exec apptainer exec \$userns_flag \${CONTAINER_FLAGS:-} \$gpu_flag -B \"$repo_root:$repo_root\" \"\$CONTAINER\" env CONTAINER_INNER=1 bash \"\$(cd \"\$(dirname \"\$0\")\" && pwd)/.run_script.sh\""
  echo 'fi'
}
