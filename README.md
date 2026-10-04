# Impact — PR Change Analysis

A GitHub Action that runs [impact](https://github.com/Easlkad/impact) on
every pull request. It reports:

- the functions the pull request changes;
- every function that calls them, directly or transitively;
- the affected packages, HTTP endpoints, goroutine workers and tests;
- an explainable **risk** score and a separate **confidence** score.

The report goes to the job summary and, optionally, to a single pull
request comment that is updated on every push. Thresholds can fail the
check.

> **Go only.** The underlying analyzer currently supports Go repositories
> only.

## Usage

```yaml
name: Impact

on:
  pull_request:

permissions:
  contents: read
  pull-requests: write

jobs:
  impact:
    runs-on: ubuntu-latest
    steps:
      - uses: Easlkad/impact-action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

The action checks out the repository itself (with full history), so no
`actions/checkout` step is needed.

### Without a pull request comment

The report still goes to the job summary, and `pull-requests: write` is not
needed:

```yaml
permissions:
  contents: read

steps:
  - uses: Easlkad/impact-action@v1
    with:
      comment: false
```

### Fail when risk is 75 or more

```yaml
- uses: Easlkad/impact-action@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    fail-risk: 75
```

### Fail when confidence is below 50

```yaml
- uses: Easlkad/impact-action@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    fail-confidence-below: 50
```

### Longer lists in the report

```yaml
- uses: Easlkad/impact-action@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    max-items: 50 # 0 for no limit
```

### Using the reports in later steps

```yaml
- id: impact
  uses: Easlkad/impact-action@v1
- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: impact-report
    path: |
      ${{ steps.impact.outputs.report-markdown }}
      ${{ steps.impact.outputs.report-json }}
```

## Example

A Go pull request where `PaymentHandler` calls `ProcessPayment`, which calls
`SavePayment`, and only `SavePayment` changed:

```text
Risk:       MODERATE (27/100)
Confidence: HIGH (100/100)

Changed function:   SavePayment
Affected endpoint:  POST /payments
Affected test:      TestProcessPayment

Impact path:
  PaymentHandler → ProcessPayment → SavePayment [changed]
```

A one-function change is traced up to the HTTP endpoint and the test it
affects: the action reports the blast radius in functions, endpoints and
tests.

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `impact-version` | `v0.1.0` | Version of the impact CLI to install: a tag, or any version `go install` accepts |
| `fail-risk` | | Fail when risk ≥ this value (0-100). Empty: never |
| `fail-confidence-below` | | Fail when confidence < this value (0-100). Empty: never |
| `max-items` | `20` | Items per list in the Markdown report (0: no limit). The JSON report is always complete |
| `comment` | `true` | Post the report as a pull request comment (needs `github-token`) |
| `github-token` | | Token used only for the comment, usually `${{ secrets.GITHUB_TOKEN }}` |
| `checkout` | `true` | Check out the repository with full history. Set to `false` if an earlier step already ran `actions/checkout` with `fetch-depth: 0` |

## Outputs

| Output | Description |
|--------|-------------|
| `report-markdown` | Path of the Markdown report |
| `report-json` | Path of the JSON report ([schema](https://github.com/Easlkad/impact#json-output)) |
| `exit-code` | `0` no threshold violated, `3` risk threshold, `4` confidence threshold, `5` both |

The reports are written to the runner's temporary directory, not to the
repository.

## How it works

1. **Checkout:** checks out the repository with `fetch-depth: 0`. impact
   reads both commits and their merge base from git history.
2. **Install:** installs the CLI with
   `go install github.com/Easlkad/impact/cmd/impact@<impact-version>`,
   using the Go of the runner. It goes into the runner's temporary
   directory, so the PATH of your later steps is unchanged.
3. **Analyze:** runs
   `impact analyze . <base-sha> <head-sha> --merge-base` twice, with
   `--format json` and with `--format markdown`.
   - The SHAs are `github.event.pull_request.base.sha` and
     `github.event.pull_request.head.sha`, never branch names.
   - `--merge-base` makes the analysis match the "Files changed" tab, even
     when the base branch has moved on.
4. **Summary:** adds the Markdown report to the job summary.
5. **Comment:** if enabled, posts the report as a comment with
   `actions/github-script`, or updates the comment from the previous run. The
   comment starts with a hidden `<!-- impact-report -->` marker, and only
   comments by the same token's user are updated.
6. **Thresholds:** fails the action if one was violated.

### Thresholds and failures

| Situation | Job summary | Comment | Action |
|-----------|-------------|---------|--------|
| Analysis succeeded, no threshold violated | report | posted | succeeds |
| A threshold violated (`exit-code` 3, 4 or 5) | report | posted | **fails, after** the report is published |
| Analysis error (bad ref, invalid input, ...) | error note | none | **fails** |
| Comment cannot be posted | report | warning only | unaffected |

### Pull requests from forks

For pull requests from forks, GitHub gives the workflow a read-only token,
so the comment cannot be posted. The action then logs a warning and goes
on: the analysis, the job summary and the thresholds work as usual.
Commenting is always optional; the job summary is the report of record.

## Requirements and limitations

- Runs on `pull_request` events only. The base and head commits come from
  the event.
- The analyzer supports Go repositories only. A pull request without Go
  changes gets a short "No Go files changed" report.
- Go must be available on the runner to install the CLI. It is preinstalled
  on GitHub-hosted runners; on self-hosted runners, add `actions/setup-go`
  before this action.
- The action is tested for GitHub-hosted Linux runners.

## Versions

Use the major version tag, `Easlkad/impact-action@v1`, to receive
compatible updates. Releases are tagged `v1.0.0`, `v1.0.1`, and so on. The
`v1` tag moves to the latest `v1.x.y`. Pin a full version or a commit SHA
for fully reproducible workflows.

The `impact-version` input pins the CLI separately.

### Testing an unpublished impact CLI

The default `impact-version` must exist as a published tag of
`github.com/Easlkad/impact`. Before a CLI version is published, either:

- install from a branch or commit: `impact-version: main`, which needs the
  CLI repository to be public; or
- build impact yourself and point the action to the binary with the
  `IMPACT_BIN` environment variable, which skips the installation:

  ```yaml
  - run: go build -o "$RUNNER_TEMP/impact" ./path/to/impact/cmd/impact
  - uses: Easlkad/impact-action@v1
    env:
      IMPACT_BIN: ${{ runner.temp }}/impact
  ```

`IMPACT_MODULE` similarly replaces the installed package, for example to
install a fork.

## Development

```sh
bash tests/scripts.test.sh        # install.sh, run.sh, check.sh with fake commands
bash tests/action.test.sh         # action.yml structure and wiring (needs yq and node)
node --test tests/comment.test.js # comment.js with a fake GitHub client
```

The shell logic lives in `scripts/`; `action.yml` only connects the
scripts. Inputs reach the scripts through environment variables, never
through `${{ }}` expressions inside shell code.
