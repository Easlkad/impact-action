#!/usr/bin/env bash
# Runs impact on the pull request, writes the Markdown and JSON reports, and
# adds the Markdown report to the job summary.
#
# Environment:
#   IMPACT_BIN              the impact binary (from install.sh)
#   BASE_SHA, HEAD_SHA      the pull request commits
#   FAIL_RISK, FAIL_CONFIDENCE_BELOW, MAX_ITEMS, COMMENT   action inputs
#   HAS_TOKEN               "true" when a github-token was given
#   IMPACT_REPORT_DIR       where to write the reports (default $RUNNER_TEMP/impact)
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY   set by GitHub Actions
#
# Step outputs: report-markdown, report-json, exit-code, comment.
#
# Exits 0 when the analysis ran, even if a threshold is violated: the
# verdict is in the exit-code output (0, 3, 4 or 5), applied by check.sh
# once the report is published. Exits 1 on invalid inputs and on analysis
# errors.
set -euo pipefail

fail() {
  echo "::error title=Impact::$*"
  exit 1
}

# is_uint reports whether $1 is a non-negative integer.
is_uint() {
  case $1 in
  '' | *[!0-9]*) return 1 ;;
  *) return 0 ;;
  esac
}

# check_threshold fails unless $2 is empty or an integer from 0 to 100.
check_threshold() {
  local name=$1 value=$2
  if [ -n "$value" ] && { ! is_uint "$value" || [ "$value" -gt 100 ]; }; then
    fail "$name must be empty or a number from 0 to 100, got '$value'"
  fi
}

# lower prints $1 in lower case.
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# build_args sets ANALYZE_ARGS, the arguments common to both runs, and
# MARKDOWN_ARGS, the arguments of the Markdown run, which applies the
# thresholds.
build_args() {
  ANALYZE_ARGS=(analyze . "$BASE_SHA" "$HEAD_SHA" --merge-base)
  MARKDOWN_ARGS=(--format markdown --max-items "$MAX_ITEMS")
  if [ -n "$FAIL_RISK" ]; then
    MARKDOWN_ARGS+=(--fail-risk "$FAIL_RISK")
  fi
  if [ -n "$FAIL_CONFIDENCE_BELOW" ]; then
    MARKDOWN_ARGS+=(--fail-confidence-below "$FAIL_CONFIDENCE_BELOW")
  fi
}

# analysis_failed reports a failed impact run in the job summary and fails.
analysis_failed() {
  {
    echo "## Impact Analysis"
    echo
    echo "The analysis failed with exit code $1. See the job log for details."
  } >>"$GITHUB_STEP_SUMMARY"
  fail "impact analyze failed with exit code $1"
}

main() {
  : "${IMPACT_BIN:?IMPACT_BIN is not set}"
  if [ -z "${BASE_SHA:-}" ] || [ -z "${HEAD_SHA:-}" ]; then
    fail "no pull request commits: this action runs on pull_request events"
  fi
  FAIL_RISK=${FAIL_RISK:-}
  FAIL_CONFIDENCE_BELOW=${FAIL_CONFIDENCE_BELOW:-}
  MAX_ITEMS=${MAX_ITEMS:-20}
  check_threshold fail-risk "$FAIL_RISK"
  check_threshold fail-confidence-below "$FAIL_CONFIDENCE_BELOW"
  is_uint "$MAX_ITEMS" || fail "max-items must be a non-negative number, got '$MAX_ITEMS'"
  local comment
  comment=$(lower "${COMMENT:-true}")
  if [ "$comment" != true ] && [ "$comment" != false ]; then
    fail "comment must be true or false, got '${COMMENT:-}'"
  fi

  local dir=${IMPACT_REPORT_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is not set}/impact}
  mkdir -p "$dir"
  local markdown="$dir/impact-report.md" json="$dir/impact-report.json"
  build_args

  # The JSON report is complete and has no thresholds: any failure is an error.
  local code=0
  "$IMPACT_BIN" "${ANALYZE_ARGS[@]}" --format json >"$json" || code=$?
  if [ "$code" -ne 0 ]; then
    analysis_failed "$code"
  fi

  # The Markdown run applies the thresholds; 3, 4 and 5 are its verdicts.
  code=0
  "$IMPACT_BIN" "${ANALYZE_ARGS[@]}" "${MARKDOWN_ARGS[@]}" >"$markdown" || code=$?
  case $code in
  0 | 3 | 4 | 5) ;;
  *) analysis_failed "$code" ;;
  esac

  cat "$markdown" >>"$GITHUB_STEP_SUMMARY"

  if [ "$comment" = true ] && [ "${HAS_TOKEN:-false}" != true ]; then
    echo "::notice title=Impact::No pull request comment: the github-token input is not set. The report is in the job summary."
    comment=false
  fi

  {
    echo "report-markdown=$markdown"
    echo "report-json=$json"
    echo "exit-code=$code"
    echo "comment=$comment"
  } >>"$GITHUB_OUTPUT"
  echo "Reports: $markdown, $json (exit code $code)"
}

# Run main unless the file is sourced, as the tests do.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
