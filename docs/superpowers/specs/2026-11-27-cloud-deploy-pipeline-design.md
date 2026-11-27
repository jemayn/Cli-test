# Umbraco Cloud deploy pipeline (GitHub Actions + `umbraco` CLI) — design

Date: 27-11-2026 · Status: draft, awaiting approval · Size: small (proof of concept)

## Intent

Proof of concept: deploy this Umbraco 18 Cloud project from GitHub Actions using the `umbraco` CLI
instead of Cloud's own git remote. Every change goes to **test** first, then to **Live's deployment
slot**, where automated smoke checks run *before* the slot is swapped into production. A failed check
rejects the slot so production is never touched.

## Goals / non-goals / anti-goals

- **Goals:** push-to-`main` pipeline; build once, deploy the identical output to test and the Live slot;
  human approval gate before Live; smoke checks on the slot; swap only the deployment that was checked.
- **Non-goals:** PR/branch builds, Playwright or content-level tests, rollback beyond `reject`,
  production-Cloud (`api.umbraco.io`) support beyond a one-line switch.
- **Anti-goals:** swapping a slot that wasn't verified; Live running a different build than test;
  any secret in the repo.

## Constraints (verified 27-11-2026)

- Cloud project lives on the **dev Cloud API**: every CLI call needs
  `UMBRACO_CLOUD_API_URL=https://api.dev-cloud.umbraco.com` (user-provided). With it, the local
  CI/CD key authenticates; without it, 401.
- Environments (from `umbraco cloud environments list`): `test` → `live`, both `canTarget: true`.
- URLs: test `https://test-cli-test.euwest01.rainbowsrock.net`, live
  `https://cli-test.euwest01.rainbowsrock.net`, Live slot `https://prewarm-cli-test.euwest01.rainbowsrock.net`
  (slot URL per user; slot was still provisioning at time of writing).
- CLI is a prerelease on MyGet: `dotnet tool install --global Umbraco.Cli --prerelease
  --add-source https://www.myget.org/F/umbracoprereleases/api/v3/index.json`
  (current version `0.1.1-alpha.58.g7ba0e32`).
- Repo `jemayn/Cli-test` is **public** → GitHub environment required reviewers work on the free plan.
- Target framework `net10.0`.

## Approaches

Release trigger (user picked **A**):

- **A. One branch, one run** — push to `main` → test → approval gate → Live slot → verify → swap.
  Same build everywhere; simplest. **Chosen.**
- B. Two branches (`develop` → test, `main` → Live) — git-flow friendly, but Live gets a build that
  never ran on test.
- C. Tags (`main` → test, `v*` tag → Live) — explicit releases, more ceremony than a POC needs.

Verification (user picked **smoke checks**): HTTP checks only; Playwright deferred.

Deployment type (*my call*): **artifact** deployment of `dotnet publish` output rather than git/source
deployment, so the bytes swapped into Live are exactly what passed on test.

## Design

`.github/workflows/deploy.yml`, triggers: `push` to `main`, `workflow_dispatch`.
Workflow-level env: `UMBRACO_CLOUD_API_URL`, `UMBRACO_CLOUD_API_KEY` / `UMBRACO_CLOUD_PROJECT_ID`
from repo secrets. `concurrency: deploy-cloud` (no cancel-in-progress) so two runs never fight over the slot.

1. **build** — setup .NET 10, `dotnet publish src/Cli.Test -c Release -o out`, upload `out` as a
   workflow artifact.
2. **deploy-test** — download artifact, install CLI,
   `umbraco cloud deployments deploy -e test --path out --type artifact --no-progress`
   (waits for completion), then smoke-check the test URL.
3. **deploy-live-slot** — GitHub environment `live` (required reviewer: repo owner). Download the same
   artifact, deploy with `-e live --slot -o json`, capture the deployment ID, smoke-check the slot URL.
   - pass → `umbraco cloud deployments swap -e live --deployment-id <id>`, then smoke-check live URL.
   - fail → `umbraco cloud deployments reject -e live --deployment-id <id>`; job fails.

**Smoke check** (one reusable shell script, `.github/scripts/smoke.sh <base-url>`): `GET /` and
`GET /umbraco` must end in HTTP 200 (following redirects); retry every 15 s for up to ~5 min to cover
warm-up. *Added during planning (my call):* the build writes the commit SHA to
`wwwroot/build-info.txt`, and the smoke check also requires `GET /build-info.txt` to equal it — an
un-deployed slot was observed answering `/` with 200 (Azure "Welcome" page), so status codes alone
can't prove the slot runs this build.

## Calls left to the builder (flag in review)

- *My call:* pin the CLI version (env var `UMBRACO_CLI_VERSION`) rather than always taking the latest
  prerelease — an alpha can change flags under us. Bump deliberately.
- *My call:* deployment ID parsing from `-o json` — exact JSON shape unknown until the first real
  slot deployment (no CLI deployments exist on the project yet); verify on first run.
- *My call:* `--message` = commit subject + short SHA, `--version` = run number, for traceability in Cloud.
- *User action:* add repo secrets `UMBRACO_CLOUD_API_KEY`, `UMBRACO_CLOUD_PROJECT_ID`; create GitHub
  environment `live` with themselves as required reviewer (I can do the environment via `gh api` on request).
