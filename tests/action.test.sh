#!/usr/bin/env bash
# Tests of action.yml: metadata, inputs, outputs, and the wiring between the
# steps and the scripts. Requires yq (mikefarah/yq v4) and node, both
# preinstalled on GitHub-hosted Ubuntu runners.
#
# Usage: bash tests/action.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION=$ROOT/action.yml
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
check() {
  local name=$1
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name"
  fi
}
q() { yq -r "$1" "$ACTION"; }
eq() { [ "$1" = "$2" ] || { echo "   got: $1"$'\n'"  want: $2"; return 1; }; }

check "action.yml is valid YAML" yq -e '.' "$ACTION" >/dev/null

# Marketplace metadata.
check "name" eq "$(q .name)" "Impact — PR Change Analysis"
check "description" test -n "$(q .description)"
check "author" eq "$(q .author)" "Easlkad"
check "branding icon" eq "$(q .branding.icon)" "git-pull-request"
check "branding color" eq "$(q .branding.color)" "purple"
check "composite action" eq "$(q .runs.using)" "composite"

# Inputs and their defaults.
check "inputs" eq "$(q '.inputs | keys | join(" ")')" \
  "impact-version fail-risk fail-confidence-below max-items comment github-token checkout"
check "impact-version is pinned" eq "$(q '.inputs.impact-version.default')" "v0.1.0"
check "no threshold by default" eq "$(q '.inputs.fail-risk.default')$(q '.inputs.fail-confidence-below.default')" ""
check "max-items default" eq "$(q '.inputs.max-items.default')" "20"
check "comment default" eq "$(q '.inputs.comment.default')" "true"
check "no token by default" eq "$(q '.inputs.github-token.default')" ""
check "all inputs optional" eq "$(q '[.inputs[] | select(.required == true)] | length')" "0"
check "all inputs described" eq "$(q '[.inputs[] | select(.description == null)] | length')" "0"

# Every input the steps use is declared.
used=$(grep -o 'inputs\.[a-z-]*' "$ACTION" | sed 's/inputs\.//' | sort -u)
for name in $used; do
  check "input $name is declared" test "$(q ".inputs | has(\"$name\")")" = true
done

# Outputs come from the analyze step, which run.sh writes.
check "outputs" eq "$(q '.outputs | keys | join(" ")')" "report-markdown report-json exit-code"
for name in report-markdown report-json exit-code; do
  check "output $name" eq "$(q ".outputs.$name.value")" "\${{ steps.analyze.outputs.$name }}"
done

# Every step output referenced is written by the script of that step.
for ref in $(grep -o 'steps\.[a-z]*\.outputs\.[a-z-]*' "$ACTION" | sort -u); do
  step=$(echo "$ref" | cut -d. -f2)
  name=$(echo "$ref" | cut -d. -f4)
  script=$(q ".runs.steps[] | select(.id == \"$step\") | .run" | grep -o 'scripts/[a-z]*\.sh')
  check "$ref is written by $script" grep -q "echo \"$name=" "$ROOT/$script"
done

# Run steps use bash and call an existing script, without the executable bit.
count=$(q '[.runs.steps[] | select(.run != null)] | length')
for i in $(seq 0 $((count - 1))); do
  run=$(q "[.runs.steps[] | select(.run != null)][$i].run")
  shell=$(q "[.runs.steps[] | select(.run != null)][$i].shell")
  check "run step $i uses bash" eq "$shell" "bash"
  check "run step $i calls a script with bash" eq "$(echo "$run" | grep -c '^bash "\$GITHUB_ACTION_PATH/scripts/[a-z]*\.sh"$')" "1"
  script=$(echo "$run" | grep -o 'scripts/[a-z]*\.sh')
  check "run step $i script $script exists" test -f "$ROOT/$script"
done

# No expression inside shell code: inputs reach the scripts through env,
# which rules out script injection.
check "no \${{ }} in run blocks" eq "$(q '[.runs.steps[].run | select(. != null) | select(test("\$\{\{"))] | length')" "0"

# Checkout: full history, optional.
check "checkout action" eq "$(q '.runs.steps[0].uses')" "actions/checkout@v4"
check "checkout full history" eq "$(q '.runs.steps[0].with.fetch-depth')" "0"
check "checkout can be skipped" eq "$(q '.runs.steps[0].if')" "inputs.checkout == 'true'"

# The SHAs come from the pull request event, never from branch names.
check "base SHA" eq "$(q '.runs.steps[] | select(.id == "analyze") | .env.BASE_SHA')" '${{ github.event.pull_request.base.sha }}'
check "head SHA" eq "$(q '.runs.steps[] | select(.id == "analyze") | .env.HEAD_SHA')" '${{ github.event.pull_request.head.sha }}'
check "token not given to the analysis" eq "$(q '.runs.steps[] | select(.id == "analyze") | .env | has("GITHUB_TOKEN")')" "false"

# Step order: the thresholds are applied last, after the comment.
check "step order" eq "$(q '[.runs.steps[].name] | join(" | ")')" \
  "Check out the repository with full history | Install impact | Analyze the pull request | Comment on the pull request | Apply the thresholds"
check "comment step condition" eq "$(q '.runs.steps[3].if')" "steps.analyze.outputs.comment == 'true'"
check "comment uses github-script" eq "$(q '.runs.steps[3].uses')" "actions/github-script@v7"

# The inline github-script code loads scripts/comment.js and posts the
# report: run it as github-script would, with a fake client.
q '.runs.steps[3].with.script' >"$WORK/script.js"
printf '%s\n## Impact Analysis\n' '<!-- impact-report -->' >"$WORK/report.md"
cat >"$WORK/harness.js" <<'EOF'
const fs = require('fs');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const body = fs.readFileSync(process.argv[2], 'utf8');
const created = [];
const github = {
  rest: {
    users: { getAuthenticated: async () => { throw Object.assign(new Error('no'), { status: 403 }); } },
    issues: {
      listComments: async () => ({ data: [] }),
      createComment: async (args) => { created.push(args); return { data: { html_url: 'url' } }; },
    },
  },
  paginate: async (m, a) => (await m(a)).data,
};
const context = { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 1 } } };
const core = { info: () => {}, warning: (m) => { throw new Error('warning: ' + m); } };
new AsyncFunction('github', 'context', 'core', 'require', body)(github, context, core, require)
  .then(() => {
    if (created.length !== 1 || !created[0].body.startsWith('<!-- impact-report -->')) throw new Error('no comment created');
    console.log('github-script snippet posted the report');
  })
  .catch((e) => { console.error(e.message); process.exit(1); });
EOF
check "github-script snippet runs" env IMPACT_ACTION_PATH="$ROOT" IMPACT_REPORT="$WORK/report.md" \
  node "$WORK/harness.js" "$WORK/script.js"

echo "action: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
