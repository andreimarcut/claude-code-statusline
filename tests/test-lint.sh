#!/usr/bin/env bash
# Static checks for every shell script in the repo:
#   - `bash -n` (syntax / parse) on all .sh files — always run.
#   - `shellcheck` on all .sh files — only if shellcheck is installed
#     (gracefully skipped otherwise, so this passes on a bare box).
#
# Run:  ./tests/test-lint.sh   (or via ../run-tests.sh)
# Exit: 0 if all checks pass (or shellcheck absent), 1 on any failure.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Collect every .sh under the repo (tests included), excluding native/target.
mapfile -t SH_FILES < <(find "$ROOT" -name '*.sh' -not -path '*/native/target/*' -not -path '*/.git/*' | sort)

fail=0

echo "== bash -n (syntax) on $((${#SH_FILES[@]})) shell scripts =="
for f in "${SH_FILES[@]}"; do
  if bash -n "$f" 2>/tmp/_ln_err; then
    printf '  ok   bash -n %s\n' "${f#"$ROOT"/}"
  else
    fail=1
    printf '  FAIL bash -n %s\n' "${f#"$ROOT"/}"
    sed 's/^/         /' /tmp/_ln_err
  fi
done
rm -f /tmp/_ln_err

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  for f in "${SH_FILES[@]}"; do
    if shellcheck -x "$f" >/tmp/_sc_out 2>&1; then
      printf '  ok   shellcheck %s\n' "${f#"$ROOT"/}"
    else
      fail=1
      printf '  FAIL shellcheck %s\n' "${f#"$ROOT"/}"
      sed 's/^/         /' /tmp/_sc_out
    fi
  done
  rm -f /tmp/_sc_out
else
  echo "  SKIP shellcheck not installed (bash -n already ran above)"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "RESULT: lint FAILED"
  exit 1
fi
echo "RESULT: lint passed"
exit 0
