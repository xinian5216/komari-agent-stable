#!/usr/bin/env bash
#
# Self-test for scripts/release-guard.sh. No network, no GitHub, no registry: both
# the gh CLI and docker are replaced by stubs on PATH, so the guard's decisions can
# be checked deterministically.
#
#   bash .github/tests/test-release-guard.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="${ROOT}/.github/scripts/release-guard.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BIN="${WORK}/bin"
STATE="${WORK}/state"
mkdir -p "$BIN" "${STATE}/assets"

pass=0
fail=0
check() { # check <description> <command...>
	local description="$1"
	shift
	if "$@" > /dev/null 2>&1; then
		printf '  ok   %s\n' "$description"
		pass=$((pass + 1))
	else
		printf '  FAIL %s\n' "$description"
		fail=$((fail + 1))
	fi
}

# ---------------------------------------------------------------- stubs

cat > "${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GH_STATE:?FAKE_GH_STATE must be set}"
[ "$1" = "api" ] || { echo "stub gh: unexpected command: $*" >&2; exit 9; }
shift
if [ "${1:-}" = "-H" ]; then
	# -H "Accept: application/octet-stream" /repos/<repo>/releases/assets/<id>
	asset_path="${3:-}"
	id="${asset_path##*/}"
	[ -f "${state}/assets/${id}" ] || { echo "stub gh: no such asset ${id}" >&2; exit 1; }
	cat "${state}/assets/${id}"
else
	[ -f "${state}/release.json" ] || { echo "stub gh: no release.json" >&2; exit 1; }
	cat "${state}/release.json"
fi
STUB
chmod +x "${BIN}/gh"

cat > "${BIN}/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# usage from the guard: docker buildx imagetools inspect <ref>
if [ "${1:-}" = "buildx" ] && [ "${2:-}" = "imagetools" ] && [ "${3:-}" = "inspect" ]; then
	ref="${4:-}"
	for existing in ${FAKE_DOCKER_EXISTING:-}; do
		if [ "$existing" = "$ref" ]; then
			echo "manifest for ${ref}"
			exit 0
		fi
	done
	exit 1
fi
echo "stub docker: unexpected command: $*" >&2
exit 9
STUB
chmod +x "${BIN}/docker"

export PATH="${BIN}:${PATH}"
export FAKE_GH_STATE="$STATE"
# Point the guard at the stubs explicitly: overriding PATH is not reliable on every
# platform (Windows picks up gh.exe from the real PATH).
export KOMARI_GH_BIN="${BIN}/gh"
export KOMARI_DOCKER_BIN="${BIN}/docker"

DIST="${WORK}/dist"
mkdir -p "$DIST"
printf 'binary-amd64-payload\n' > "${DIST}/komari-linux-amd64"
printf 'checksums-payload\n' > "${DIST}/SHA256SUMS"

write_release_json() { # write_release_json <name> <id>
	local name="$1" id="$2"
	printf '{"tag_name":"v1.5.0-stable.1","assets":[{"id":%s,"name":"%s"}]}\n' "$id" "$name" > "${STATE}/release.json"
}

# ---------------------------------------------------------------- assets

echo "== assets: missing asset is planned for upload =="
printf '{"tag_name":"v1.5.0-stable.1","assets":[]}\n' > "${STATE}/release.json"
: > "${WORK}/plan.txt"
check "exit 0 when nothing is published yet" \
	bash "$GUARD" assets "xinian5216/komari-stable" "v1.5.0-stable.1" "${WORK}/plan.txt" "${DIST}/komari-linux-amd64"
check "the plan lists the missing asset" \
	grep -qx "komari-linux-amd64" "${WORK}/plan.txt"
check "the log announces the upload" \
	bash -c "bash '$GUARD' assets xinian5216/komari-stable v1.5.0-stable.1 '${WORK}/plan2.txt' '${DIST}/komari-linux-amd64' 2>&1 | grep -q 'UPLOAD komari-linux-amd64'"

echo "== assets: identical bytes are skipped =="
write_release_json "komari-linux-amd64" 111
cp "${DIST}/komari-linux-amd64" "${STATE}/assets/111"
: > "${WORK}/plan.txt"
check "exit 0 for an identical published asset" \
	bash "$GUARD" assets "xinian5216/komari-stable" "v1.5.0-stable.1" "${WORK}/plan.txt" "${DIST}/komari-linux-amd64"
check "nothing is planned for upload" \
	bash -c "[ ! -s '${WORK}/plan.txt' ]"
check "the log says SKIP" \
	bash -c "bash '$GUARD' assets xinian5216/komari-stable v1.5.0-stable.1 '${WORK}/plan2.txt' '${DIST}/komari-linux-amd64' 2>&1 | grep -q 'SKIP komari-linux-amd64'"

echo "== assets: different bytes must fail =="
write_release_json "komari-linux-amd64" 222
printf 'a different build\n' > "${STATE}/assets/222"
: > "${WORK}/plan.txt"
check "exit non-zero for a changed rebuild" \
	bash -c "! bash '$GUARD' assets xinian5216/komari-stable v1.5.0-stable.1 '${WORK}/plan.txt' '${DIST}/komari-linux-amd64'"
check "the failure names immutable release asset mismatch" \
	bash -c "bash '$GUARD' assets xinian5216/komari-stable v1.5.0-stable.1 '${WORK}/plan.txt' '${DIST}/komari-linux-amd64' 2>&1 | grep -q 'immutable release asset mismatch'"
check "nothing was planned for upload" \
	bash -c "[ ! -s '${WORK}/plan.txt' ]"

echo "== assets: SHA256SUMS is guarded the same way =="
write_release_json "SHA256SUMS" 333
printf 'a different checksum file\n' > "${STATE}/assets/333"
check "exit non-zero when SHA256SUMS changed" \
	bash -c "! bash '$GUARD' assets xinian5216/komari-stable v1.5.0-stable.1 '${WORK}/plan.txt' '${DIST}/SHA256SUMS'"
cp "${DIST}/SHA256SUMS" "${STATE}/assets/333"
check "exit 0 when SHA256SUMS is identical" \
	bash "$GUARD" assets "xinian5216/komari-stable" "v1.5.0-stable.1" "${WORK}/plan.txt" "${DIST}/SHA256SUMS"

echo "== assets: a partial retry only fills the gaps =="
write_release_json "komari-linux-amd64" 444
cp "${DIST}/komari-linux-amd64" "${STATE}/assets/444"
: > "${WORK}/plan.txt"
check "exit 0 when one asset is published and another is missing" \
	bash "$GUARD" assets "xinian5216/komari-stable" "v1.5.0-stable.1" "${WORK}/plan.txt" \
		"${DIST}/komari-linux-amd64" "${DIST}/SHA256SUMS"
check "only the missing asset is planned" \
	bash -c "grep -qx SHA256SUMS '${WORK}/plan.txt' && ! grep -qx komari-linux-amd64 '${WORK}/plan.txt'"

echo "== verify-sums: a checksum file must describe the published bytes =="
printf 'binary-amd64-payload\n' > "${DIST}/komari-linux-amd64"
( cd "${DIST}" && sha256sum komari-linux-amd64 > SHA256SUMS.true )
write_release_json "komari-linux-amd64" 555
cp "${DIST}/komari-linux-amd64" "${STATE}/assets/555"
check "exit 0 when the checksum file matches the published asset" \
	bash "$GUARD" verify-sums "xinian5216/komari-stable" "v1.5.0-stable.1" "${DIST}/SHA256SUMS.true"

printf 'checksums-for-a-different-build\n' > "${DIST}/SHA256SUMS.wrong"
printf '%s  komari-linux-amd64\n' "0000000000000000000000000000000000000000000000000000000000000000" > "${DIST}/SHA256SUMS.wrong"
check "exit non-zero when the checksum file disagrees with the published asset" \
	bash -c "! bash '$GUARD' verify-sums xinian5216/komari-stable v1.5.0-stable.1 '${DIST}/SHA256SUMS.wrong'"
check "the failure names the mismatch" \
	bash -c "bash '$GUARD' verify-sums xinian5216/komari-stable v1.5.0-stable.1 '${DIST}/SHA256SUMS.wrong' 2>&1 | grep -q 'does not describe the published assets'"

printf 'nothing  komari-linux-mips\n' > "${DIST}/SHA256SUMS.missing"
check "exit non-zero when the checksum file lists an asset that is not published" \
	bash -c "! bash '$GUARD' verify-sums xinian5216/komari-stable v1.5.0-stable.1 '${DIST}/SHA256SUMS.missing'"

# ---------------------------------------------------------------- image tags

echo "== image: an existing fixed version tag must fail =="
export FAKE_DOCKER_EXISTING="ghcr.io/xinian5216/komari-stable:v1.5.0-stable.1 ghcr.io/xinian5216/komari-stable:stable"
check "exit non-zero for an existing version tag" \
	bash -c "! bash '$GUARD' image ghcr.io/xinian5216/komari-stable:v1.5.0-stable.1 ghcr.io/xinian5216/komari-stable:stable"
check "the failure is explicit about immutability" \
	bash -c "bash '$GUARD' image ghcr.io/xinian5216/komari-stable:v1.5.0-stable.1 ghcr.io/xinian5216/komari-stable:stable 2>&1 | grep -q 'immutable image tag'"

echo "== image: a new version tag is allowed =="
check "exit 0 for a version tag that does not exist yet" \
	bash "$GUARD" image ghcr.io/xinian5216/komari-stable:v1.5.0-stable.2 ghcr.io/xinian5216/komari-stable:stable

echo "== image: an unreachable registry must not be mistaken for 'not published' =="
export FAKE_DOCKER_EXISTING=""
check "exit non-zero when the registry cannot be reached" \
	bash -c "! bash '$GUARD' image ghcr.io/xinian5216/komari-stable:v1.5.0-stable.2 ghcr.io/xinian5216/komari-stable:stable"
check "the failure names the infrastructure problem" \
	bash -c "bash '$GUARD' image ghcr.io/xinian5216/komari-stable:v1.5.0-stable.2 ghcr.io/xinian5216/komari-stable:stable 2>&1 | grep -q 'cannot reach the registry'"

echo
echo "release guard self-test: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
