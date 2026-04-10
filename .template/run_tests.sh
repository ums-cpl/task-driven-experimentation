#!/usr/bin/env bash
# Declarative test runner for .test files.
#
# Layout: `.test` files anywhere under `tests/` (arbitrarily nested)
#
# Directives (lines starting with # are comments; blank lines ignored):
#   RUN: <args>                                 invoke test workdir's .template/run_tasks.sh with args
#   EXIT: <code>                                expected exit code for the last RUN
#   STDOUT: ... END_STDOUT                      expected stdout (exact)
#   STDOUT_FILE: <path>                         compare stdout to file
#   STDERR: ... END_STDERR                      expected stderr (exact)
#   STDERR_FILE: <path>                         compare stderr to file
#   FILE_EXISTS: <path>                         assert a regular file exists
#   FILE_NOT_EXISTS: <path>                     assert nothing exists at path
#   FILE_CONTENT: <path> ... END_FILE_CONTENT   assert file exists and matches block
#   FILES_MATCH: <repo_path> <test_path>        compare two files
#
# Failure output:
#   On FAIL, write <stem>.failed next to the .test file.
#   Keep the corresponding <stem>.workdir directory next to the .test file.
#   For STDOUT_FILE/STDERR_FILE/FILES_MATCH mismatches, also write an .actual.*
#   beside the expected reference file (same convention as the reference runner).
#
# Path variables in directive paths:
#   Paths may contain literal tokens:
#     $TASKS, $ASSETS, $TEST_WORKDIR, $TEST_NAME
#
# Resolution rule:
#   - Expand the tokens into absolute paths (except $TEST_NAME, which expands to the test stem string).
#   - If the resulting path is absolute, use it as-is.
#   - Otherwise, resolve relative to the directory containing the .test file.
#
# Usage: ./.template/run_tests.sh [PATH_OR_GLOB ...]
#   Default: all `tests/**/*.test` recursively

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RUN_WORKDIR_SUFFIX=".workdir"
RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

die() {
  echo -e "${RED}Error:${RESET} $*" >&2
  exit 1
}

print_test_path() {
  local f="$1"
  local p="${f#"$REPO_ROOT"/}"
  if [[ "$p" == "$f" ]]; then
    echo "$f"
  else
    echo "$p"
  fi
}

actual_file_path() {
  # Insert ".actual" before the final extension: foo.txt -> foo.actual.txt
  local path="$1"
  local dir base stem ext
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ "$base" == *.* ]]; then
    ext="${base##*.}"
    stem="${base%.*}"
    echo "$dir/${stem}.actual.${ext}"
  else
    echo "$dir/${base}.actual"
  fi
}

rel_to_test_dir() {
  local abs="$1"
  if [[ "$abs" == "$TEST_DIR/"* ]]; then
    echo "${abs#"$TEST_DIR/"}"
  else
    echo "$abs"
  fi
}

if [[ ! -d "$REPO_ROOT/tasks" ]]; then
  die "tasks/ not found at $REPO_ROOT/tasks"
fi
if [[ ! -d "$REPO_ROOT/.template" ]]; then
  die ".template/ not found at $REPO_ROOT/.template"
fi

collect_test_files() {
  local patterns=("$@")
  local files=()

  shopt -s nullglob globstar
  if [[ ${#patterns[@]} -eq 0 ]]; then
    patterns=("tests")
  fi

  local pat m
  for pat in "${patterns[@]}"; do
    for m in $pat; do
      if [[ -d "$m" ]]; then
        files+=("$m"/**/*.test)
      elif [[ -f "$m" && "$m" == *.test ]]; then
        files+=("$m")
      fi
    done
  done
  shopt -u nullglob globstar

  if [[ ${#files[@]} -eq 0 ]]; then
    # Let main decide how to report/exit; avoid relying on `die` inside
    # process substitution, which may be swallowed by bash.
    return 0
  fi
  # Canonicalize to absolute paths for stable comparisons and workdir placement.
  local abs
  local out=()
  local uniq
  for f in "${files[@]}"; do
    abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    out+=("$abs")
  done
  printf '%s\n' "${out[@]}" | sort -u
}

resolve_test_context() {
  local test_file="$1"

  local abs
  abs="$(cd "$(dirname "$test_file")" && pwd)/$(basename "$test_file")"
  TEST_FILE_ABS="$abs"

  TEST_DIR="$(dirname "$abs")"
  local base
  base="$(basename "$abs")"
  TEST_STEM="${base%.test}"
  TEST_NAME="$TEST_STEM"
  WORK_ROOT="$TEST_DIR/${TEST_STEM}${RUN_WORKDIR_SUFFIX}"
  TASKS_DIR="$WORK_ROOT/tasks"
  ASSETS_DIR="$WORK_ROOT/assets"
}

setup_workdir() {
  rm -rf "$WORK_ROOT"
  mkdir -p "$WORK_ROOT"

  # Symlink template + assets; copy tasks (required to keep workdir independent).
  ln -sfn "$REPO_ROOT/.template" "$WORK_ROOT/.template"
  ln -sfn "$REPO_ROOT/assets" "$WORK_ROOT/assets"

  # Create the workdir-local wrapper that workload managers use to re-inject
  # environment variables in direct/cluster/array modes.
  cat > "$WORK_ROOT/run_tasks.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export REPOSITORY_ROOT="$WORK_ROOT"
export TASKS="$TASKS_DIR"
export ASSETS="$ASSETS_DIR"
export TEMPLATE="$WORK_ROOT/.template"
export RUN_TASKS_SCRIPT="$WORK_ROOT/run_tasks.sh"

exec "\$TEMPLATE/run_tasks.sh" "\$@"
EOF
  chmod +x "$WORK_ROOT/run_tasks.sh"

  rm -rf "$TASKS_DIR"
  cp -a "$REPO_ROOT/tasks" "$TASKS_DIR"
}

log_append() {
  LOG_LINES+=("$1")
}

invoke_run_tasks() {
  local args_str="$1"
  local run_sh="$WORK_ROOT/.template/run_tasks.sh"

  if [[ ! -f "$run_sh" ]]; then
    die "Expected run_tasks.sh at $run_sh (workdir setup bug?)"
  fi

  local out err
  out="$(mktemp)"
  err="$(mktemp)"

  set +e
  (
    cd "$WORK_ROOT" 2>/dev/null || true
    # shellcheck disable=SC2086
    eval "set -- $args_str"
    "$run_sh" "$@"
  ) >"$out" 2>"$err"

  LAST_EXIT=$?
  set -e
  LAST_STDOUT="$(cat "$out")"
  LAST_STDERR="$(cat "$err")"
  rm -f "$out" "$err"
}

str_eq() {
  [[ "$1" == "$2" ]]
}

expand_path_vars() {
  local path="$1"

  # Replace literal tokens (these are not shell variables inside the .test file).
  path="${path//\$TASKS/$TASKS_DIR}"
  path="${path//\$ASSETS/$ASSETS_DIR}"
  path="${path//\$TEST_WORKDIR/$WORK_ROOT}"
  path="${path//\$TEST_NAME/$TEST_STEM}"

  echo "$path"
}

resolve_path() {
  local raw="$1"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  local expanded
  expanded="$(expand_path_vars "$raw")"
  if [[ "$expanded" == /* ]]; then
    echo "$expanded"
  else
    echo "$TEST_DIR/$expanded"
  fi
}

run_one_test_file() {
  local test_file="$1"

  resolve_test_context "$test_file"
  setup_workdir

  local fail_path="${TEST_DIR}/${TEST_STEM}.failed"
  rm -f "$fail_path"
  LOG_LINES=()
  TEST_OK=1
  TEST_FAIL_REASON=""

  local last_stdout="" last_stderr="" last_exit=0
  local LAST_RUN_LINE=""
  local line buf expect_path actual_path repo_path test_path

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing for comment check
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ -z "${line//[[:space:]]/}" ]]; then
      continue
    fi

    if [[ "$line" == RUN:* ]]; then
      LAST_RUN_LINE="$line"
      local args
      args="${line#RUN:}"
      args="${args#"${args%%[![:space:]]*}"}"
      # Allow $TASKS/$ASSETS/etc tokens inside RUN directives.
      args="$(expand_path_vars "$args")"
      invoke_run_tasks "$args"
      last_stdout="$LAST_STDOUT"
      last_stderr="$LAST_STDERR"
      last_exit="$LAST_EXIT"
      continue
    fi

    if [[ "$line" == EXIT:* ]]; then
      local want
      want="${line#EXIT:}"
      want="${want#"${want%%[![:space:]]*}"}"
      want="${want%"${want##*[![:space:]]}"}"
      if [[ "$want" != "$last_exit" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="EXIT expected $want got $last_exit"
        log_append "${LAST_RUN_LINE:-RUN:}"
        log_append "EXIT: $want"
        log_append "ACTUAL_EXIT: $last_exit"
        break
      fi
      continue
    fi

    if [[ "$line" == "STDOUT:" ]]; then
      buf=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "END_STDOUT" ]] && break
        if [[ -n "$buf" ]]; then
          buf+=$'\n'
        fi
        buf+="$line"
      done
      # Normalise absolute paths in runner output so expectations stay portable.
      # (Manifest now contains absolute TASK PATH and WORKLOAD_MANAGER script paths.)
      local normalized_last_stdout
      normalized_last_stdout="$last_stdout"
      normalized_last_stdout="$(printf '%s' "$normalized_last_stdout" | sed \
        -e "s#${TASKS_DIR%/}/#tasks/#g" \
        -e "s#${WORK_ROOT%/}/.template/#.template/#g" \
        -e "s#${REPO_ROOT%/}/.template/#.template/#g")"
      if ! str_eq "$buf" "$normalized_last_stdout"; then
        TEST_OK=0
        TEST_FAIL_REASON="STDOUT mismatch"
        log_append "STDOUT:"
        log_append "$buf"
        log_append "END_STDOUT"
        log_append "ACTUAL_STDOUT:"
        log_append "$normalized_last_stdout"
        log_append "END_ACTUAL_STDOUT"
        break
      fi
      continue
    fi

    if [[ "$line" == STDOUT_FILE:* ]]; then
      expect_path="${line#STDOUT_FILE:}"
      if [[ -z "${expect_path%%[![:space:]]*}" ]]; then
        expect_path="${expect_path#"${expect_path%%[![:space:]]*}"}"
      fi
      expect_path="${expect_path#"${expect_path%%[![:space:]]*}"}"
      expect_path="${expect_path%"${expect_path##*[![:space:]]}"}"
      local expected_file
      expected_file="$(resolve_path "$expect_path")"
      if [[ ! -f "$expected_file" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="STDOUT_FILE missing: $expected_file"
        log_append "STDOUT_FILE: ${line#STDOUT_FILE:}"
        log_append "ACTUAL_STDOUT_FILE: (expected file missing)"
        break
      fi
      local exp_content
      exp_content="$(cat -- "$expected_file")"
      if ! str_eq "$exp_content" "$last_stdout"; then
        TEST_OK=0
        TEST_FAIL_REASON="STDOUT_FILE mismatch"
        actual_path="$(actual_file_path "$expected_file")"
        printf '%s' "$last_stdout" >"$actual_path"
        log_append "STDOUT_FILE: $(rel_to_test_dir "$expected_file")"
        log_append "ACTUAL_STDOUT_FILE: $(rel_to_test_dir "$actual_path")"
        break
      fi
      continue
    fi

    if [[ "$line" == "STDERR:" ]]; then
      buf=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "END_STDERR" ]] && break
        if [[ -n "$buf" ]]; then
          buf+=$'\n'
        fi
        buf+="$line"
      done
      if ! str_eq "$buf" "$last_stderr"; then
        TEST_OK=0
        TEST_FAIL_REASON="STDERR mismatch"
        log_append "STDERR:"
        log_append "$buf"
        log_append "END_STDERR"
        log_append "ACTUAL_STDERR:"
        log_append "$last_stderr"
        log_append "END_ACTUAL_STDERR"
        break
      fi
      continue
    fi

    if [[ "$line" == STDERR_FILE:* ]]; then
      expect_path="${line#STDERR_FILE:}"
      expect_path="${expect_path#"${expect_path%%[![:space:]]*}"}"
      expect_path="${expect_path%"${expect_path##*[![:space:]]}"}"
      local expected_file
      expected_file="$(resolve_path "$expect_path")"
      if [[ ! -f "$expected_file" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="STDERR_FILE missing: $expected_file"
        log_append "STDERR_FILE: ${line#STDERR_FILE:}"
        log_append "ACTUAL_STDERR_FILE: (expected file missing)"
        break
      fi
      local exp_content
      exp_content="$(cat -- "$expected_file")"
      if ! str_eq "$exp_content" "$last_stderr"; then
        TEST_OK=0
        TEST_FAIL_REASON="STDERR_FILE mismatch"
        actual_path="$(actual_file_path "$expected_file")"
        printf '%s' "$last_stderr" >"$actual_path"
        log_append "STDERR_FILE: $(rel_to_test_dir "$expected_file")"
        log_append "ACTUAL_STDERR_FILE: $(rel_to_test_dir "$actual_path")"
        break
      fi
      continue
    fi

    if [[ "$line" == FILE_EXISTS:* ]]; then
      repo_path="${line#FILE_EXISTS:}"
      repo_path="${repo_path#"${repo_path%%[![:space:]]*}"}"
      repo_path="${repo_path%"${repo_path##*[![:space:]]}"}"
      local abs_path
      abs_path="$(resolve_path "$repo_path")"
      if [[ ! -f "$abs_path" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILE_EXISTS failed: $repo_path"
        log_append "FILE_EXISTS: $repo_path"
        log_append "ACTUAL_FILE_EXISTS: FAIL"
        break
      fi
      continue
    fi

    if [[ "$line" == FILE_NOT_EXISTS:* ]]; then
      repo_path="${line#FILE_NOT_EXISTS:}"
      repo_path="${repo_path#"${repo_path%%[![:space:]]*}"}"
      repo_path="${repo_path%"${repo_path##*[![:space:]]}"}"
      local abs_path
      abs_path="$(resolve_path "$repo_path")"
      if [[ -e "$abs_path" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILE_NOT_EXISTS failed: $repo_path"
        log_append "FILE_NOT_EXISTS: $repo_path"
        log_append "ACTUAL_FILE_NOT_EXISTS: FAIL"
        break
      fi
      continue
    fi

    if [[ "$line" == FILE_CONTENT:* ]]; then
      repo_path="${line#FILE_CONTENT:}"
      repo_path="${repo_path#"${repo_path%%[![:space:]]*}"}"
      repo_path="${repo_path%"${repo_path##*[![:space:]]}"}"
      local abs_path
      abs_path="$(resolve_path "$repo_path")"

      buf=""
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "END_FILE_CONTENT" ]] && break
        if [[ -n "$buf" ]]; then
          buf+=$'\n'
        fi
        buf+="$line"
      done

      local actual_content
      if [[ ! -f "$abs_path" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILE_CONTENT: file missing: $repo_path"
        log_append "FILE_CONTENT: $repo_path"
        log_append "$buf"
        log_append "END_FILE_CONTENT"
        log_append "ACTUAL_FILE_CONTENT:"
        log_append "(file missing)"
        log_append "END_ACTUAL_FILE_CONTENT"
        break
      fi
      actual_content="$(cat -- "$abs_path")"
      if ! str_eq "$actual_content" "$buf"; then
        TEST_OK=0
        TEST_FAIL_REASON="FILE_CONTENT mismatch: $repo_path"
        log_append "FILE_CONTENT: $repo_path"
        log_append "$buf"
        log_append "END_FILE_CONTENT"
        log_append "ACTUAL_FILE_CONTENT:"
        log_append "$actual_content"
        log_append "END_ACTUAL_FILE_CONTENT"
        break
      fi
      continue
    fi

    if [[ "$line" == FILES_MATCH:* ]]; then
      local rest
      rest="${line#FILES_MATCH:}"
      rest="${rest#"${rest%%[![:space:]]*}"}"

      repo_path="${rest%% *}"
      test_path="${rest#* }"
      test_path="${test_path#"${test_path%%[![:space:]]*}"}"
      test_path="${test_path%"${test_path##*[![:space:]]}"}"

      if [[ -z "${repo_path:-}" || -z "${test_path:-}" || "$repo_path" == "$rest" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILES_MATCH requires two paths"
        log_append "FILES_MATCH: (parse error)"
        log_append "ACTUAL_FILES_MATCH: FAIL (invalid directive)"
        break
      fi

      local repo_abs ref_abs
      repo_abs="$(resolve_path "$repo_path")"
      ref_abs="$(resolve_path "$test_path")"

      if [[ ! -f "$repo_abs" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILES_MATCH: repo file missing: $repo_path"
        log_append "FILES_MATCH: $repo_path $test_path"
        log_append "ACTUAL_FILES_MATCH: FAIL (repo file missing)"
        break
      fi
      if [[ ! -f "$ref_abs" ]]; then
        TEST_OK=0
        TEST_FAIL_REASON="FILES_MATCH: reference missing: $test_path"
        log_append "FILES_MATCH: $repo_path $test_path"
        log_append "ACTUAL_FILES_MATCH: FAIL (reference missing)"
        break
      fi

      if ! cmp -s "$repo_abs" "$ref_abs"; then
        TEST_OK=0
        TEST_FAIL_REASON="FILES_MATCH mismatch: $repo_path vs $test_path"
        actual_path="$(actual_file_path "$ref_abs")"
        cp -- "$repo_abs" "$actual_path"
        log_append "FILES_MATCH: $repo_path $test_path"
        log_append "ACTUAL_FILES_MATCH: FAIL $(rel_to_test_dir "$actual_path")"
        break
      fi
      continue
    fi

    TEST_OK=0
    TEST_FAIL_REASON="Unknown directive: $line"
    log_append "Unknown directive: $line"
    break
  done < "$TEST_FILE_ABS"

  if [[ "$TEST_OK" -eq 1 ]]; then
    rm -rf "$WORK_ROOT"
    echo -e "${GREEN}PASS${RESET} $(print_test_path "$test_file")"
    return 0
  fi

  {
    echo "# Test failed: $TEST_FAIL_REASON"
    printf '%s\n' "${LOG_LINES[@]}"
  } >"$fail_path"

  echo -e "${RED}FAIL${RESET} $(print_test_path "$test_file") ($TEST_FAIL_REASON) — $(print_test_path "$fail_path")"
  return 1
}

# --- main ---
patterns=("$@")
mapfile -t TEST_FILES < <(collect_test_files "${patterns[@]}")

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  die "No .test files matched."
fi

passed=0
failed=0
failed_list=()

for tf in "${TEST_FILES[@]}"; do
  if run_one_test_file "$tf"; then
    ((passed++)) || true
  else
    ((failed++)) || true
    failed_list+=("$tf")
  fi
done

total=$((passed + failed))
echo ""
echo "Total: $total, Passed: $passed, Failed: $failed"
if [[ $failed -gt 0 ]]; then
  echo -e "${RED}Failed:${RESET}"
  printf '  %s\n' "${failed_list[@]}"
  exit 1
fi
exit 0
