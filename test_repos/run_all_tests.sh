#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_REPOS_DIR="$REPO_ROOT/test_repos"

if [[ ! -d "$TEST_REPOS_DIR" ]]; then
  echo "Error: test_repos/ not found at $TEST_REPOS_DIR" >&2
  exit 1
fi

failed=0
repos=()
shopt -s nullglob
for d in "$TEST_REPOS_DIR"/*; do
  [[ -d "$d" ]] || continue
  repos+=("$d")
done
shopt -u nullglob

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "Error: no test repos found under $TEST_REPOS_DIR" >&2
  exit 1
fi

echo "Running test repos (${#repos[@]})..."
for repo in $(printf '%s\n' "${repos[@]}" | sort -V); do
  echo ""
  echo "=== Repo: $(basename "$repo") ==="
  if ! (cd "$repo" && bash "./.template/run_tests.sh"); then
    failed=1
    echo "Repo failed: $(basename "$repo")" >&2
  fi
done

if [[ $failed -ne 0 ]]; then
  echo ""
  echo "Some test repos failed." >&2
  exit 1
fi

echo ""
echo -e "\e[32mAll test repos passed.\e[0m"
exit 0

