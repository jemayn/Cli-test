#!/usr/bin/env bash
# Tests for smoke.sh. Serves a temp directory with a tiny Node static server and
# runs smoke.sh against it. Usage: bash .github/scripts/smoke.test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
smoke="$here/smoke.sh"
failures=0
root=""
server_pid=""

start_server() {
  root="$(mktemp -d)"
  local portfile="$root.port"
  node -e '
    const http = require("http"), fs = require("fs"), path = require("path");
    const [root, portfile] = process.argv.slice(1);
    http.createServer((req, res) => {
      let p = path.join(root, decodeURIComponent(req.url.split("?")[0]));
      try { if (fs.statSync(p).isDirectory()) p = path.join(p, "index.html"); } catch {}
      fs.readFile(p, (err, data) => {
        if (err) { res.writeHead(404); res.end("not found"); return; }
        res.writeHead(200); res.end(data);
      });
    }).listen(0, "127.0.0.1", function () { fs.writeFileSync(portfile, String(this.address().port)); });
  ' "$root" "$portfile" &
  server_pid=$!
  for _ in $(seq 1 50); do [[ -s "$portfile" ]] && break; sleep 0.1; done
  url="http://127.0.0.1:$(cat "$portfile")"
}

stop_server() {
  kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null
  rm -rf "$root" "$root.port"
}

# expect <name> <expected-exit> <smoke args...>
expect() {
  local name="$1" want="$2"; shift 2
  local log; log="$(mktemp)"
  bash "$smoke" "$@" >"$log" 2>&1
  local got=$?
  if [[ "$got" == "$want" ]]; then
    echo "PASS $name"
  else
    echo "FAIL $name (exit $got, want $want)"; sed 's/^/    /' "$log"
    failures=$((failures + 1))
  fi
  rm -f "$log"
}

export SMOKE_TIMEOUT_SECONDS=4 SMOKE_INTERVAL_SECONDS=1

start_server
echo "<h1>home</h1>" >"$root/index.html"
mkdir -p "$root/umbraco"; echo "<h1>login</h1>" >"$root/umbraco/index.html"
echo "abc123" >"$root/build-info.txt"
expect "all pages 200" 0 "$url" abc123
stop_server

start_server
echo "<h1>home</h1>" >"$root/index.html"
echo "abc123" >"$root/build-info.txt"
expect "missing /umbraco fails" 1 "$url" abc123
stop_server

start_server
echo "<h1>home</h1>" >"$root/index.html"
mkdir -p "$root/umbraco"; echo "<h1>login</h1>" >"$root/umbraco/index.html"
echo "old" >"$root/build-info.txt"
expect "stale build marker fails" 1 "$url" abc123
stop_server

start_server
echo "<h1>home</h1>" >"$root/index.html"
mkdir -p "$root/umbraco"; echo "<h1>login</h1>" >"$root/umbraco/index.html"
expect "no sha skips marker" 0 "$url"
stop_server

start_server
echo "<h1>home</h1>" >"$root/index.html"
echo "abc123" >"$root/build-info.txt"
( sleep 2; mkdir -p "$root/umbraco"; echo "<h1>login</h1>" >"$root/umbraco/index.html" ) &
SMOKE_TIMEOUT_SECONDS=6 expect "recovers after warm-up" 0 "$url" abc123
wait $! 2>/dev/null
stop_server

expect "unreachable host fails" 1 "http://127.0.0.1:1"

if (( failures > 0 )); then echo "$failures test(s) failed"; exit 1; fi
echo "all tests passed"
