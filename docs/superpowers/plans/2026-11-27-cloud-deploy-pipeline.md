# Umbraco Cloud Deploy Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GitHub Actions workflow that builds this site once, deploys it to Cloud `test`, then (after approval) to the `live` deployment slot, smoke-checks the slot and swaps or rejects it.

**Architecture:** One workflow, three jobs (`build` → `deploy-test` → `deploy-live`), sharing one published artifact. A single bash script does all HTTP verification. All Cloud calls go through the `umbraco` CLI against the dev Cloud API.

**Tech Stack:** GitHub Actions (ubuntu-latest), .NET 10 SDK, `Umbraco.Cli` 0.1.1-alpha.58.g7ba0e32 (MyGet), bash + curl.

**Spec:** `docs/superpowers/specs/2026-11-27-cloud-deploy-pipeline-design.md`

## Global Constraints

- Every CLI call has `UMBRACO_CLOUD_API_URL=https://api.dev-cloud.umbraco.com` (workflow-level `env`).
- Secrets only from GitHub: `UMBRACO_CLOUD_API_KEY`, `UMBRACO_CLOUD_PROJECT_ID`. Nothing secret in the repo; `.env.umbraco` stays ignored.
- CLI install: `dotnet tool install --global Umbraco.Cli --version "$UMBRACO_CLI_VERSION" --add-source https://www.myget.org/F/umbracoprereleases/api/v3/index.json`, `UMBRACO_CLI_VERSION: 0.1.1-alpha.58.g7ba0e32`.
- Environment aliases: `test`, `live`. URLs: test `https://test-cli-test.euwest01.rainbowsrock.net`, slot `https://prewarm-cli-test.euwest01.rainbowsrock.net`, live `https://cli-test.euwest01.rainbowsrock.net`.
- Same published output to test and slot (artifact deployment, `--type artifact`).
- `concurrency: { group: deploy-cloud, cancel-in-progress: false }`.
- Every CLI call uses `--no-progress`.
- Do not push, set secrets or create GitHub environments without the user's explicit go-ahead in-session.

## Review Focus

- **Empty / un-deployed slot answers 200** (verified 27-11-2026: slot `/` serves "Microsoft Azure App Service - Welcome") → smoke must fail unless `/build-info.txt` equals the run's SHA. Pinned by Task 1 test `stale build marker fails`.
- **Slot deploy fails or times out before an ID is known** → still attempt `reject -e live` (no ID) so nothing lingers awaiting swap; job fails. Task 3.
- **Run cancelled during slot verification** → reject runs on `cancelled()` too; otherwise the slot waits up to 2 h (`--max-swap-wait` default). Task 3.
- **Site still warming up** (first requests 5xx / timeouts) → smoke retries every 15 s up to 300 s, not fail-fast. Task 1 test `recovers after warm-up`.
- **Swap succeeds but live check fails** → no auto-rollback (non-goal); job fails red with the live URL in the log. Task 3.

---

### Task 1: Smoke-check script

**Files:**
- Create: `.github/scripts/smoke.sh`
- Test: `.github/scripts/smoke.test.sh`

**Interfaces:**
- Produces: `smoke.sh <base-url> [expected-sha]` → exit 0 when `GET <base>/` and `GET <base>/umbraco` both end in 200 (curl `-L`) **and**, if `expected-sha` given, `GET <base>/build-info.txt` body (trimmed) equals it. Retries the whole set every `SMOKE_INTERVAL_SECONDS` (default 15) until `SMOKE_TIMEOUT_SECONDS` (default 300), then exit 1. Each attempt logs one line per URL with its status. Per-request `--max-time 30`.

- [ ] **Step 1: Write the failing test** — `smoke.test.sh` starts `python -m http.server` on a free port over a temp dir and asserts, with `SMOKE_TIMEOUT_SECONDS=4 SMOKE_INTERVAL_SECONDS=1`:
  - `all pages 200` — dir has `index.html`, `umbraco/index.html`, `build-info.txt` = `abc123` → `smoke.sh $url abc123` exits 0.
  - `missing /umbraco fails` — no `umbraco/` → exits 1.
  - `stale build marker fails` — `build-info.txt` = `old` → `smoke.sh $url abc123` exits 1.
  - `no sha skips marker` — no `build-info.txt` → `smoke.sh $url` exits 0.
  - `recovers after warm-up` — `umbraco/index.html` created by a background `sleep 2` → exits 0 with timeout 6.
  - `unreachable host fails` — `http://127.0.0.1:1` → exits 1.
  Prints `PASS`/`FAIL <name>` per case, exits non-zero on any failure.
- [ ] **Step 2: Run** `bash .github/scripts/smoke.test.sh` — Expected: fails (script missing).
- [ ] **Step 3: Implement `smoke.sh`** per Interfaces (`set -euo pipefail`, curl `-s -o -w '%{http_code}'`).
- [ ] **Step 4: Run** `bash .github/scripts/smoke.test.sh` — Expected: 6× PASS, exit 0. Also `bash .github/scripts/smoke.sh https://test-cli-test.euwest01.rainbowsrock.net` with `SMOKE_TIMEOUT_SECONDS=20` → exit 1 today (`/umbraco` 404 until first deploy); log shows statuses.
- [ ] **Step 5: Commit** `feat(ci): add smoke-check script for Cloud deployments` (`git update-index --chmod=+x` both scripts).

### Task 2: Workflow — build + deploy to test

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: `.github/scripts/smoke.sh` (Task 1).
- Produces: workflow `Deploy to Umbraco Cloud`; job `build` uploads artifact `site` (the publish dir, including `wwwroot/build-info.txt` = `${{ github.sha }}`); job `deploy-test`; reusable step pattern "install CLI" (setup-dotnet 10.0.x + tool install per Global Constraints, then `umbraco --version`).

- [ ] **Step 1: Write `deploy.yml`** — triggers `push: branches [main]` + `workflow_dispatch`; workflow `env`: `UMBRACO_CLOUD_API_URL`, `UMBRACO_CLI_VERSION`, `UMBRACO_CLOUD_API_KEY: ${{ secrets.UMBRACO_CLOUD_API_KEY }}`, `UMBRACO_CLOUD_PROJECT_ID: ${{ secrets.UMBRACO_CLOUD_PROJECT_ID }}`; `concurrency` per constraints; `permissions: contents: read`.
  - `build`: checkout, setup-dotnet `10.0.x`, `dotnet publish src/Cli.Test/Cli.Test.csproj -c Release -o out`, `echo "${{ github.sha }}" > out/wwwroot/build-info.txt`, `actions/upload-artifact` name `site`, path `out`, `include-hidden-files: true`.
  - `deploy-test` (`needs: build`, `environment: test`): checkout, download `site` → `out`, install CLI, `umbraco cloud deployments deploy -e test --path out --type artifact --message "$(git log -1 --format='%s (%h)')" --version "${{ github.run_number }}" --no-progress`, then `.github/scripts/smoke.sh <test-url> ${{ github.sha }}`.
- [ ] **Step 2: Lint** — `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 -color` — Expected: no output, exit 0.
- [ ] **Step 3: Local dry-run of the build half** — run the `dotnet publish` command locally into a scratch dir; Expected: succeeds and `wwwroot/` exists in output (so the marker path is valid).
- [ ] **Step 4: Commit** `feat(ci): build once and deploy to Cloud test via umbraco CLI`.
- [ ] **Step 5: GitHub setup + first run (needs user go-ahead)** — with approval: `gh secret set UMBRACO_CLOUD_API_KEY` / `UMBRACO_CLOUD_PROJECT_ID` (values piped from `.env.umbraco`, never echoed), push `main`, `gh run watch`. Expected: `build` and `deploy-test` green; test URL `/umbraco` now 200.
- [ ] **Step 6: Capture the deployment JSON shape** — locally (dev API env set) `umbraco cloud deployments list -o json --no-progress` and `deployments show -e test -o json`; record the ID field name and status field for Task 3.

### Task 3: Workflow — live slot, verify, swap / reject

**Files:**
- Modify: `.github/workflows/deploy.yml` (add job `deploy-live`)

**Interfaces:**
- Consumes: artifact `site`, "install CLI" steps, `smoke.sh` (Tasks 1–2); deployment ID JSON field from Task 2 Step 6.
- Produces: job `deploy-live` (`needs: deploy-test`, `environment: live`).

- [ ] **Step 1: Add `deploy-live`** — checkout, download `site`, install CLI, then:
  - `slot` step (`id: slot`): `umbraco cloud deployments deploy -e live --slot --path out --type artifact --message … --version … -o json --no-progress > slot.json`; `jq -r '<field from Task 2 Step 6>' slot.json` → `$GITHUB_OUTPUT` `deployment_id`; `cat slot.json` for the log.
  - `verify`: `.github/scripts/smoke.sh <slot-url> ${{ github.sha }}`.
  - `swap`: `umbraco cloud deployments swap -e live --deployment-id ${{ steps.slot.outputs.deployment_id }} --no-progress`.
  - `verify-live`: `.github/scripts/smoke.sh <live-url> ${{ github.sha }}`.
  - `reject` (`if: (failure() || cancelled()) && steps.swap.outcome != 'success'`): `reject -e live` plus `--deployment-id` when the output is non-empty; `--no-progress`; this step must not mask the original failure (job stays red).
- [ ] **Step 2: Lint** — same actionlint command; Expected: clean.
- [ ] **Step 3: Commit** `feat(ci): deploy to live slot, smoke-check, swap or reject`.
- [ ] **Step 4: GitHub environment (needs user go-ahead)** — `gh api -X PUT repos/jemayn/Cli-test/environments/live` with `reviewers` = user `jemayn`; `test` environment without reviewers.
- [ ] **Step 5: Happy path run** — push; approve in GitHub UI; Expected: slot smoke passes, swap succeeds, `https://cli-test.euwest01.rainbowsrock.net/build-info.txt` = pushed SHA.
- [ ] **Step 6: Reject path run** — trigger `workflow_dispatch`, approve, and cancel the run while `verify` is retrying (no test-only failure switch is added to the workflow). Expected: `reject` step runs, `umbraco cloud deployments show -e live -o json` reports the slot deployment rejected, and live `/build-info.txt` still equals the previous SHA.
