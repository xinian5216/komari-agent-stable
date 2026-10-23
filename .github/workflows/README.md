# Workflow Design Notes

This fork maintains the `stable` branch. Read `../REQUIRED_CHECKS.md` for required
contexts and failure policy; workflow files are the source of truth for triggers,
tool versions and permissions.

## Maintained workflows

| Workflow | Purpose | Output / gate |
| --- | --- | --- |
| `remote-control-ci.yml` | Monitoring-only guard, deterministic Go tests, vet, cross-compilation, installer policy and startup payload checks | `required-gate` |
| `supply-chain-ci.yml` | Immutable Actions pins, release-guard tests, installer and migration safety tests | `supply-chain-gate` |
| `security-scan.yml` | Reachable-vulnerability govulncheck and CodeQL | `security-gate` |
| `secret-scan.yml` | Full-history and working-tree credential scans | `secret-gate` |
| `migration-test.yml` | Real official-Agent takeover rehearsal for affected paths or manual dispatch | Migration evidence; not a substitute for the four gates |
| `release.yml` | Published non-prerelease: platform binaries and checksums; dispatch: missing checksum repair only | GitHub Release assets |
| `release-docker.yml` | Published non-prerelease or explicit tag dispatch | Fixed version and moving `latest` multi-arch image tags |

`build.yml` and `generate-release-notes.yml` were deliberately removed. Do not
restore them or introduce dependencies on the removed release-note credentials.
Source attribution and fork changes are recorded in `../../UPSTREAM.md`.

## Local and CI checks

Use `../../AGENTS.md` for the local checklist. The deterministic Go suite skips
only `TestICMPPing`, `TestTCPPing` and `TestHTTPPing`: they depend on public hosts
or raw-socket privileges. Run the complete suite separately when the environment
supports it and disclose those external checks rather than hiding failures.

Installer/migration shell tests create temporary services and may need root.
Run them in an isolated environment as CI does, never against production units.
The startup-payload job verifies the actual reporting contract, not only a build.

## Release contract

- Changes enter `stable` through a PR with every required gate successful.
  Recheck the exact merged commit before tagging; a successful PR check belongs
  to the PR commit, not automatically to a squash merge.
- Use the Go version declared by `go.mod`; do not give build, security and release
  jobs conflicting toolchains. Other tool versions belong in their workflows.
- Release and Docker workflows check out the requested immutable tag, not the
  current default branch. Fixed image tags and published assets cannot change.
- `release.yml` uses the tag's `../scripts/release-guard.sh`: identical assets are
  skipped, changed bytes fail, and only missing files may be uploaded.
  The dispatch path regenerates missing checksums from published binaries,
  verifies the published assets, and refuses legacy tags without the guard.
- Preserve binary names: `komari-agent-${GOOS}-${GOARCH}`, plus `.exe` on Windows.
  The Dockerfile expects prebuilt Linux binaries with those names.
- Embed `update.CurrentVersion` from the release tag, dropping its leading `v`,
  so updater comparisons and the reported version match the published binary.
- Produce per-asset `.sha256` and `SHA256SUMS`; verify actual downloaded bytes,
  embedded versions and image platforms after publication.
- Stable release workflows skip prerelease events. Agent's moving Docker
  `latest` is distinct from an immutable version tag; do not copy Server's
  frozen-floating-tag policy onto Agent without an explicit maintenance decision.

## Retained upstream snapshot workflow

`snapshot.yml` remains as a legacy upstream workflow. Its push trigger and runtime
guards require `main`, which this fork currently does not have. It is not part of
the maintained `stable` release path, and manual dispatch from `stable` must fail
its branch guard. Do not create or move a branch just to activate it.

If this path is explicitly re-enabled later, review it separately: it creates
`Snapshot-*` prereleases, removes older snapshot prereleases and tags, and moves
the Docker `snapshot` tag. Those are different lifecycle rules from immutable
stable releases. They must not publish stable `latest` or feed stable Agent
auto-update. Inspect `../../update/` for the current update-selection logic;
do not assume upstream library behavior still defines the fork.

## Scope of authorization

Push, merge, publication and production rollout follow the scope authorized for
the current task. Existing authorization need not be requested again. A repository
release does not authorize installing or upgrading any production Agent.
