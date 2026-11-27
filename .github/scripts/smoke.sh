#!/usr/bin/env bash
# Smoke-check an Umbraco site after a deployment.
#
# Usage: smoke.sh <base-url> [expected-sha]
#
# Passes when GET <base-url>/ and GET <base-url>/umbraco both end in HTTP 200
# (following redirects) and, if expected-sha is given, GET <base-url>/build-info.txt
# returns exactly that SHA - proving the site runs this build, not a placeholder page.
# Retries every SMOKE_INTERVAL_SECONDS (default 15) until SMOKE_TIMEOUT_SECONDS
# (default 300) to ride out warm-up.
set -euo pipefail

base="${1:?usage: smoke.sh <base-url> [expected-sha]}"
base="${base%/}"
expected_sha="${2:-}"
timeout="${SMOKE_TIMEOUT_SECONDS:-300}"
interval="${SMOKE_INTERVAL_SECONDS:-15}"

status_of() {
  curl -sL -o /dev/null -w '%{http_code}' --max-time 30 "$1" 2>/dev/null || true
}

check_once() {
  local ok=0 code
  for path in / /umbraco; do
    code="$(status_of "$base$path")"
    echo "  $base$path -> ${code:-000}"
    [[ "$code" == "200" ]] || ok=1
  done
  if [[ -n "$expected_sha" ]]; then
    local body
    body="$(curl -sfL --max-time 30 "$base/build-info.txt" 2>/dev/null | tr -d '[:space:]' || true)"
    echo "  $base/build-info.txt -> '${body}' (want '$expected_sha')"
    [[ "$body" == "$expected_sha" ]] || ok=1
  fi
  return "$ok"
}

deadline=$(( $(date +%s) + timeout ))
attempt=1
while true; do
  echo "Smoke check $base (attempt $attempt)"
  if check_once; then
    echo "Smoke check passed: $base"
    exit 0
  fi
  if (( $(date +%s) + interval > deadline )); then
    echo "Smoke check FAILED after ${timeout}s: $base" >&2
    exit 1
  fi
  sleep "$interval"
  attempt=$((attempt + 1))
done
