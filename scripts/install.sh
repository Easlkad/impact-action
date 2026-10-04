#!/usr/bin/env bash
# Installs the impact CLI and writes its path to the step output impact-bin.
#
# Environment:
#   IMPACT_VERSION  version to install: a tag such as v0.1.0, or any version
#                   "go install" accepts (required unless IMPACT_BIN is set)
#   IMPACT_BIN      path of an existing impact binary, used instead of
#                   installing one; for testing unpublished versions
#   IMPACT_MODULE   package to install (default github.com/Easlkad/impact/cmd/impact)
#   RUNNER_TEMP, GITHUB_OUTPUT  set by GitHub Actions
#
# The binary is installed into $RUNNER_TEMP/impact-bin, so neither the Go
# installation nor the PATH of later steps is changed.
set -euo pipefail

fail() {
  echo "::error title=Impact::$*"
  exit 1
}

main() {
  local bin
  if [ -n "${IMPACT_BIN:-}" ]; then
    [ -f "$IMPACT_BIN" ] && [ -x "$IMPACT_BIN" ] || fail "IMPACT_BIN=$IMPACT_BIN is not an executable file"
    bin=$IMPACT_BIN
    echo "Using the impact binary from IMPACT_BIN: $bin"
  else
    local version=${IMPACT_VERSION:-}
    local module=${IMPACT_MODULE:-github.com/Easlkad/impact/cmd/impact}
    [ -n "$version" ] || fail "the impact-version input is empty"
    command -v go >/dev/null 2>&1 || fail "Go is not installed on this runner: add actions/setup-go before this action"

    local gobin="${RUNNER_TEMP:?RUNNER_TEMP is not set}/impact-bin"
    mkdir -p "$gobin"
    echo "Installing $module@$version"
    if ! GOBIN="$gobin" go install "$module@$version"; then
      fail "could not install $module@$version. Check that impact-version names a published version of the impact CLI."
    fi
    bin="$gobin/impact"
    if [ ! -x "$bin" ] && [ -x "$bin.exe" ]; then
      bin="$bin.exe" # Windows runners
    fi
  fi

  "$bin" version
  echo "impact-bin=$bin" >>"$GITHUB_OUTPUT"
}

main "$@"
