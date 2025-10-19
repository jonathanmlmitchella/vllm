#!/usr/bin/env bash
# GodLikeLM Ultra 2025 - Post-Rebase Verification Script
# Run this BEFORE pushing to ensure code quality and correctness
set -Eeuo pipefail

# -------------- Colors --------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAILED_CHECKS=0
TOTAL_CHECKS=0
WARNED_CHECKS=0

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# -------------- Helpers --------------
section() {
  printf "${BLUE}>>> %s${NC}\n" "$1"
}

check_pass() {
  ((TOTAL_CHECKS++))
  printf "${GREEN}✓ PASS${NC}: %s\n" "$1"
}

check_fail() {
  ((TOTAL_CHECKS++))
  ((FAILED_CHECKS++))
  printf "${RED}✗ FAIL${NC}: %s\n" "$1"
}

check_warn() {
  ((TOTAL_CHECKS++))
  ((WARNED_CHECKS++))
  printf "${YELLOW}! WARN${NC}: %s\n" "$1"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_check() {
  local title="$1"; shift
  # Run a command (string) and record pass/fail without exiting the script
  set +e
  bash -lc "$*"
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    check_pass "$title"
  else
    check_fail "$title"
  fi
  return $status
}

print_header() {
  printf "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║      Post-Rebase Verification & Testing Suite            ║${NC}\n"
  printf "${CYAN}║      GodLikeLM Ultra 2025                                ║${NC}\n"
  printf "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n\n"
}

usage() {
  cat <<'EOF'
Usage: tools/post_rebase_verify.sh [options]

Options:
  --quick               Run a fast test subset (default behavior)
  --all-tests           Run broader pytest suite (skips slow/distributed/TPU)
  --changed-only        Test only files impacted by local changes vs main
  --no-lint             Skip pre-commit linters
  --no-tests            Skip pytest
  --no-docs             Skip MkDocs build check
  --manual-hooks        Also run pre-commit hooks marked "manual"
  --pytest-args "..."   Extra args to pass through to pytest
  -h, --help            Show this help

Examples:
  tools/post_rebase_verify.sh --quick
  tools/post_rebase_verify.sh --all-tests --manual-hooks --pytest-args "-k tokenization"
EOF
}

# -------------- Arg parsing --------------
QUICK=1
ALL_TESTS=0
CHANGED_ONLY=0
NO_LINT=0
NO_TESTS=0
NO_DOCS=0
RUN_MANUAL=0
USER_PYTEST_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; ALL_TESTS=0; shift ;;
    --all-tests) ALL_TESTS=1; QUICK=0; shift ;;
    --changed-only) CHANGED_ONLY=1; shift ;;
    --no-lint) NO_LINT=1; shift ;;
    --no-tests) NO_TESTS=1; shift ;;
    --no-docs) NO_DOCS=1; shift ;;
    --manual-hooks) RUN_MANUAL=1; shift ;;
    --pytest-args) USER_PYTEST_ARGS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf "${YELLOW}Unknown option:${NC} %s\n" "$1"; usage; exit 2 ;;
  esac
done

print_header

# -------------- Lint / Format (pre-commit) --------------
if [[ "$NO_LINT" -eq 0 ]]; then
  section "Code Quality Check (pre-commit linters)"
  if have_cmd pre-commit; then
    # Ensure hooks are available to run even if not installed into .git/hooks
    run_check "pre-commit (default stage)" "pre-commit run --all-files --show-diff-on-failure"
    if [[ "$RUN_MANUAL" -eq 1 ]]; then
      run_check "pre-commit (manual stage)" "pre-commit run --hook-stage manual --all-files --show-diff-on-failure"
    fi
  else
    check_warn "pre-commit not found. Install with: pip install -r requirements/lint.txt"
  fi
  echo
fi

# -------------- Unit Tests (pytest) --------------
if [[ "$NO_TESTS" -eq 0 ]]; then
  section "Running Unit Tests (pytest)"
  if have_cmd pytest; then
    # Decide which tests to run
    PYTEST_TARGETS=()
    PYTEST_COMMON_ARGS=( -q --maxfail=1 --disable-warnings --durations=15 --color=yes )
    # Markers to skip heavy tests by default
    MARKERS=( -m "not slow_test and not distributed" -k "not tpu and not cudagraph" )

    if [[ "$ALL_TESTS" -eq 1 ]]; then
      PYTEST_TARGETS=( tests )
    elif [[ "$CHANGED_ONLY" -eq 1 ]]; then
      BASE_REF="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo HEAD~1)"
      mapfile -t CHANGED_TESTS < <(git diff --name-only --diff-filter=ACMRTUXB "$BASE_REF"...HEAD | grep -E '^tests/.*\.py$' || true)
      if [[ ${#CHANGED_TESTS[@]} -gt 0 ]]; then
        PYTEST_TARGETS=( "${CHANGED_TESTS[@]}" )
      else
        # Fallback to quick set if no direct test changes
        PYTEST_TARGETS=( tests/utils.py tests/utils_ tests/tokenization tests/tool_use tests/v1/engine/test_engine_args.py tests/v1/engine/test_output_processor.py )
      fi
    else
      # QUICK default subset aimed to catch common regressions fast
      PYTEST_TARGETS=( tests/utils.py tests/utils_ tests/tokenization tests/tool_use tests/v1/engine/test_engine_args.py tests/v1/engine/test_output_processor.py )
    fi

    # Compose full command
    PYTEST_CMD=( pytest "${PYTEST_COMMON_ARGS[@]}" "${MARKERS[@]}" "${PYTEST_TARGETS[@]}" )
    if [[ -n "$USER_PYTEST_ARGS" ]]; then
      # shellcheck disable=SC2206
      EXTRA_ARGS=( $USER_PYTEST_ARGS )
      PYTEST_CMD+=( "${EXTRA_ARGS[@]}" )
    fi

    # Run
    run_check "pytest" "${PYTEST_CMD[*]}"
  else
    check_warn "pytest not found. Install with: pip install -r requirements/test.txt"
  fi
  echo
fi

# -------------- Documentation (MkDocs) --------------
if [[ "$NO_DOCS" -eq 0 ]]; then
  section "Checking Documentation (MkDocs build)"
  if have_cmd mkdocs; then
    run_check "mkdocs build --strict" "mkdocs build --strict --quiet"
  else
    check_warn "mkdocs not found. Install with: pip install -r requirements/docs.txt"
  fi
  echo
fi

# -------------- Final Summary --------------
printf "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║ ${BOLD}Summary${NC}${CYAN}: Total=%d, Passed=%d, Failed=%d, Warned=%d        ║${NC}\n" \
  "$TOTAL_CHECKS" "$((TOTAL_CHECKS-FAILED_CHECKS-WARNED_CHECKS))" "$FAILED_CHECKS" "$WARNED_CHECKS"
printf "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"

if [[ "$FAILED_CHECKS" -gt 0 ]]; then
  printf "${RED}One or more checks failed. Please address the failures above.${NC}\n"
  exit 1
fi

if [[ "$WARNED_CHECKS" -gt 0 ]]; then
  printf "${YELLOW}Completed with warnings. Consider addressing them before pushing.${NC}\n"
fi

printf "${GREEN}All checks passed.${NC}\n"
