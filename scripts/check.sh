#!/usr/bin/env bash
# Applies the risk and confidence thresholds, after the report has been
# published: fails with the exit code of the analysis if one was violated.
#
# Environment:
#   IMPACT_EXIT_CODE  exit code of the Markdown run of impact (0, 3, 4 or 5)
set -euo pipefail

code=${IMPACT_EXIT_CODE:-}
case $code in
0)
  echo "Impact: no threshold violated."
  exit 0
  ;;
3) reason="risk is at or above the fail-risk threshold" ;;
4) reason="confidence is below the fail-confidence-below threshold" ;;
5) reason="risk is at or above fail-risk, and confidence is below fail-confidence-below" ;;
*)
  echo "::error title=Impact::unexpected analysis exit code '$code'"
  exit 1
  ;;
esac

echo "::error title=Impact threshold::The $reason. See the report in the job summary."
exit "$code"
