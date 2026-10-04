#!/usr/bin/env bash
# Tests of scripts/install.sh, scripts/run.sh and scripts/check.sh.
#
# The scripts run as in the action, with the GitHub Actions environment
# simulated in a temporary directory, and fake "impact" and "go" commands
# that record their arguments.
#
# Usage: bash tests/scripts.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS=$ROOT/scripts
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); }
fail() {
  failed=$((failed + 1))
  echo "FAIL: $CURRENT: $*"
}

# assert_eq checks that $2 (actual) equals $3 (expected).
assert_eq() {
  if [ "$2" != "$3" ]; then
    fail "$1"$'\n'"   got: $2"$'\n'"  want: $3"
  else
    pass
  fi
}

assert_contains() {
  case $2 in
  *"$3"*) pass ;;
  *) fail "$1: missing '$3' in:"$'\n'"$2" ;;
  esac
}

assert_not_contains() {
  case $2 in
  *"$3"*) fail "$1: unexpected '$3' in:"$'\n'"$2" ;;
  *) pass ;;
  esac
}

# setup creates a fresh simulated runner and a fake impact binary. The fake
# writes "<format> report" to stdout, logs its arguments one call per line
# to $CALLS, and exits with $FAKE_EXIT_JSON or $FAKE_EXIT_MARKDOWN.
setup() {
  CURRENT=$1
  N=$((${N:-0} + 1))
  T=$WORK/t$N # numbered: test names contain characters unsafe in PATH
  mkdir -p "$T/bin" "$T/temp"
  export RUNNER_TEMP=$T/temp
  export GITHUB_OUTPUT=$T/output GITHUB_STEP_SUMMARY=$T/summary
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  export CALLS=$T/calls
  : >"$CALLS"
  cat >"$T/bin/impact" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CALLS"
case " $* " in
*" --format json "*) echo '{"schemaVersion": 1}'; exit "${FAKE_EXIT_JSON:-0}" ;;
*" --format markdown "*) echo '<!-- impact-report -->'; echo '## Impact Analysis'; exit "${FAKE_EXIT_MARKDOWN:-0}" ;;
*" version "* | "version") echo "impact test" ;;
esac
EOF
  chmod +x "$T/bin/impact"
  export IMPACT_BIN=$T/bin/impact BASE_SHA=base0000 HEAD_SHA=head1111
  export FAIL_RISK="" FAIL_CONFIDENCE_BELOW="" MAX_ITEMS=20 COMMENT=true HAS_TOKEN=true
  export FAKE_EXIT_JSON=0 FAKE_EXIT_MARKDOWN=0
  unset IMPACT_REPORT_DIR IMPACT_VERSION IMPACT_MODULE
}

# run_script runs a script, setting STATUS and OUT (stdout and stderr).
run_script() {
  OUT=$(bash "$SCRIPTS/$1" 2>&1)
  STATUS=$?
}

# output prints the value of a step output.
output() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# --- run.sh ---------------------------------------------------------------

setup "run: default arguments"
run_script run.sh
assert_eq "exit status" "$STATUS" 0
assert_eq "impact calls" "$(cat "$CALLS")" \
  "analyze . base0000 head1111 --merge-base --format json
analyze . base0000 head1111 --merge-base --format markdown --max-items 20"

setup "run: thresholds and max-items"
FAIL_RISK=75 FAIL_CONFIDENCE_BELOW=50 MAX_ITEMS=5 run_script run.sh
assert_eq "exit status" "$STATUS" 0
assert_eq "impact calls" "$(cat "$CALLS")" \
  "analyze . base0000 head1111 --merge-base --format json
analyze . base0000 head1111 --merge-base --format markdown --max-items 5 --fail-risk 75 --fail-confidence-below 50"

setup "run: one threshold"
FAIL_CONFIDENCE_BELOW=0 run_script run.sh
assert_eq "markdown call" "$(sed -n 2p "$CALLS")" \
  "analyze . base0000 head1111 --merge-base --format markdown --max-items 20 --fail-confidence-below 0"

setup "run: reports and outputs"
run_script run.sh
assert_eq "report-markdown" "$(output report-markdown)" "$RUNNER_TEMP/impact/impact-report.md"
assert_eq "report-json" "$(output report-json)" "$RUNNER_TEMP/impact/impact-report.json"
assert_eq "exit-code" "$(output exit-code)" 0
assert_eq "comment" "$(output comment)" true
assert_eq "markdown report" "$(cat "$RUNNER_TEMP/impact/impact-report.md")" $'<!-- impact-report -->\n## Impact Analysis'
assert_eq "json report" "$(cat "$RUNNER_TEMP/impact/impact-report.json")" '{"schemaVersion": 1}'
assert_eq "job summary" "$(cat "$GITHUB_STEP_SUMMARY")" $'<!-- impact-report -->\n## Impact Analysis'

setup "run: custom report directory"
IMPACT_REPORT_DIR=$T/reports run_script run.sh
assert_eq "report-markdown" "$(output report-markdown)" "$T/reports/impact-report.md"

for code in 3 4 5; do
  setup "run: threshold verdict $code"
  FAKE_EXIT_MARKDOWN=$code run_script run.sh
  assert_eq "exit status (verdict applied later)" "$STATUS" 0
  assert_eq "exit-code" "$(output exit-code)" "$code"
  assert_contains "job summary still written" "$(cat "$GITHUB_STEP_SUMMARY")" "## Impact Analysis"
done

for code in 1 2 7; do
  setup "run: markdown analysis error $code"
  FAKE_EXIT_MARKDOWN=$code run_script run.sh
  assert_eq "exit status" "$STATUS" 1
  assert_contains "error annotation" "$OUT" "::error title=Impact::impact analyze failed with exit code $code"
  assert_contains "job summary" "$(cat "$GITHUB_STEP_SUMMARY")" "The analysis failed with exit code $code"
  assert_eq "no outputs" "$(cat "$GITHUB_OUTPUT")" ""
done

setup "run: json analysis error"
FAKE_EXIT_JSON=1 run_script run.sh
assert_eq "exit status" "$STATUS" 1
assert_eq "markdown run skipped" "$(wc -l <"$CALLS" | tr -d ' ')" 1

setup "run: comment without token"
HAS_TOKEN=false run_script run.sh
assert_eq "exit status" "$STATUS" 0
assert_eq "comment" "$(output comment)" false
assert_contains "notice" "$OUT" "::notice title=Impact::No pull request comment"

setup "run: comment disabled"
COMMENT=FALSE run_script run.sh
assert_eq "comment" "$(output comment)" false
assert_not_contains "no notice" "$OUT" "::notice"

setup "run: comment input is case-insensitive"
COMMENT=True run_script run.sh
assert_eq "comment" "$(output comment)" true

setup "run: not a pull request"
BASE_SHA="" run_script run.sh
assert_eq "exit status" "$STATUS" 1
assert_contains "error" "$OUT" "this action runs on pull_request events"
assert_eq "impact not run" "$(cat "$CALLS")" ""

for bad in "FAIL_RISK=abc" "FAIL_RISK=101" "FAIL_RISK=-5" "FAIL_CONFIDENCE_BELOW=1.5" "MAX_ITEMS=-1" "MAX_ITEMS=ten" "COMMENT=yes"; do
  setup "run: invalid input $bad"
  env "$bad" bash "$SCRIPTS/run.sh" >"$T/out" 2>&1
  STATUS=$?
  assert_eq "exit status" "$STATUS" 1
  assert_contains "error annotation" "$(cat "$T/out")" "::error title=Impact::"
  assert_eq "impact not run" "$(cat "$CALLS")" ""
done

setup "run: boundary thresholds are valid"
FAIL_RISK=0 FAIL_CONFIDENCE_BELOW=100 MAX_ITEMS=0 run_script run.sh
assert_eq "exit status" "$STATUS" 0

# --- check.sh -------------------------------------------------------------

setup "check: no violation"
IMPACT_EXIT_CODE=0 run_script check.sh
assert_eq "exit status" "$STATUS" 0

for code in 3 4 5; do
  setup "check: violation $code"
  IMPACT_EXIT_CODE=$code run_script check.sh
  assert_eq "exit status" "$STATUS" "$code"
  assert_contains "error annotation" "$OUT" "::error title=Impact threshold::"
done
setup "check: risk message"
IMPACT_EXIT_CODE=3 run_script check.sh
assert_contains "reason" "$OUT" "risk is at or above the fail-risk threshold"

for code in "" 1 abc; do
  setup "check: unexpected code '$code'"
  IMPACT_EXIT_CODE=$code run_script check.sh
  assert_eq "exit status" "$STATUS" 1
done

# --- install.sh -----------------------------------------------------------

# fake_go puts a fake go command first in PATH. It logs its arguments and
# GOBIN, then creates $GOBIN/impact, or exits with $FAKE_GO_EXIT.
fake_go() {
  cat >"$T/bin/go" <<'EOF'
#!/usr/bin/env bash
echo "GOBIN=$GOBIN $*" >>"$CALLS"
[ "${FAKE_GO_EXIT:-0}" = 0 ] || exit "$FAKE_GO_EXIT"
printf '#!/usr/bin/env bash\necho "impact installed"\n' >"$GOBIN/impact"
chmod +x "$GOBIN/impact"
EOF
  chmod +x "$T/bin/go"
  export PATH="$T/bin:$PATH"
}

setup "install: go install of the pinned version"
unset IMPACT_BIN
fake_go
IMPACT_VERSION=v0.1.0 run_script install.sh
assert_eq "exit status" "$STATUS" 0
assert_eq "go call" "$(cat "$CALLS")" "GOBIN=$RUNNER_TEMP/impact-bin install github.com/Easlkad/impact/cmd/impact@v0.1.0"
assert_eq "impact-bin" "$(output impact-bin)" "$RUNNER_TEMP/impact-bin/impact"
assert_contains "version printed" "$OUT" "impact installed"

setup "install: custom module"
unset IMPACT_BIN
fake_go
IMPACT_VERSION=abc1234 IMPACT_MODULE=example.com/fork/cmd/impact run_script install.sh
assert_eq "go call" "$(cat "$CALLS")" "GOBIN=$RUNNER_TEMP/impact-bin install example.com/fork/cmd/impact@abc1234"

setup "install: version missing"
unset IMPACT_BIN
fake_go
IMPACT_VERSION="" run_script install.sh
assert_eq "exit status" "$STATUS" 1
assert_contains "error" "$OUT" "the impact-version input is empty"
assert_eq "go not run" "$(cat "$CALLS")" ""

setup "install: go install fails"
unset IMPACT_BIN
fake_go
FAKE_GO_EXIT=1 IMPACT_VERSION=v9.9.9 run_script install.sh
assert_eq "exit status" "$STATUS" 1
assert_contains "error" "$OUT" "could not install github.com/Easlkad/impact/cmd/impact@v9.9.9"
assert_eq "no output" "$(cat "$GITHUB_OUTPUT")" ""

setup "install: IMPACT_BIN skips the installation"
fake_go
IMPACT_VERSION=v0.1.0 run_script install.sh
assert_eq "exit status" "$STATUS" 0
assert_eq "impact-bin" "$(output impact-bin)" "$IMPACT_BIN"
assert_eq "go not run, impact version run" "$(cat "$CALLS")" "version"

setup "install: IMPACT_BIN must be executable"
IMPACT_BIN=$T/missing run_script install.sh
assert_eq "exit status" "$STATUS" 1
assert_contains "error" "$OUT" "is not an executable file"

echo "scripts: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
