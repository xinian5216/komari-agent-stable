#!/usr/bin/env bash
#
# Release immutability guard for Komari Agent Stable.
#
# Published release assets and fixed version image tags are immutable: this script
# only ever reads from GitHub and the registry, it never deletes or replaces
# anything, and it never uploads on its own.
#
#   release-guard.sh assets <repo> <tag> <plan-file> <file>...
#
#       For every file, decide whether it may still be uploaded to <repo>'s release
#       <tag>:
#         * the asset does not exist yet      -> "UPLOAD <name>" and the name is
#                                                written to <plan-file> (one per
#                                                line) so the caller can upload it;
#         * the asset exists with identical   -> "SKIP <name>", nothing to do
#           bytes                               (a workflow retry after a partial
#                                                failure is safe);
#         * the asset exists with different   -> exit 1 after printing
#           bytes                               "immutable release asset mismatch";
#
#       A published asset is never overwritten: to fix a broken release, publish the
#       next version (for example 1.5.0-stable.2).
#
#   release-guard.sh verify-sums <repo> <tag> <SHA256SUMS-file>
#
#       Fail unless every entry of <SHA256SUMS-file> matches the asset that is
#       actually published on <tag>. A checksum file is only meaningful for the
#       bytes that were really published, so it must be derived from the release -
#       never from a rebuild, which is not byte-identical.
#
#   release-guard.sh image <fixed-ref> <liveness-ref>
#
#       Fail when the immutable image reference <fixed-ref> already exists in the
#       registry (a published version tag must never be re-pointed at another
#       digest). <liveness-ref> is consulted only when <fixed-ref> is absent, to
#       tell "does not exist" apart from "registry unreachable".
#
set -euo pipefail

log() { printf '[release-guard] %s\n' "$*"; }

# The external commands can be overridden, which is how the self-test substitutes
# stubs for them (overriding PATH is not reliable on every platform).
GH_BIN="${KOMARI_GH_BIN:-gh}"
DOCKER_BIN="${KOMARI_DOCKER_BIN:-docker}"
tmp_dir="" # scratch directory, removed by the EXIT trap in assets()

# Python is used only to read the release JSON; pick whichever interpreter exists
# (CI has python3, Windows git-bash usually only has python).
python_bin() {
	if [ -n "${KOMARI_PYTHON:-}" ]; then
		printf '%s' "$KOMARI_PYTHON"
		return
	fi
	local candidate
	for candidate in python3 python; do
		# A candidate only counts when it actually runs: Windows ships a python3
		# shim that exists on PATH but exits with a broken-app error.
		if command -v "$candidate" > /dev/null 2>&1 && "$candidate" -c 'import json' > /dev/null 2>&1; then
			printf '%s' "$candidate"
			return
		fi
	done
	log "FAIL: python3 (or python) is required"
	exit 1
}

usage() {
	cat >&2 <<'USAGE'
usage:
  release-guard.sh assets <repo> <tag> <plan-file> <file>...
  release-guard.sh verify-sums <repo> <tag> <SHA256SUMS-file>
  release-guard.sh image <fixed-ref> <liveness-ref>
USAGE
	exit 2
}

assets() {
	local repo="$1" tag="$2" plan="$3"
	shift 3
	if [ "$#" -eq 0 ]; then
		log "FAIL: no files given"
		exit 2
	fi

	: > "$plan"

	local release_json
	if ! release_json="$("$GH_BIN" api "repos/${repo}/releases/tags/${tag}")"; then
		log "FAIL: cannot read the release ${tag} in ${repo}"
		exit 1
	fi

	local listing
	listing="$(printf '%s' "$release_json" | "$(python_bin)" -c '
import json, sys
release = json.load(sys.stdin)
for asset in release.get("assets") or []:
    print("%s\t%s" % (asset.get("id"), asset.get("name")))
')"

	# A global on purpose: the EXIT trap runs after this function returned, so a
	# local variable would already be gone (and set -u would turn that into a
	# spurious failure).
	tmp_dir="$(mktemp -d)"
	trap 'rm -rf "${tmp_dir:-}"' EXIT

	local path name id remote_hash local_hash
	local to_upload=0
	for path in "$@"; do
		[ -f "$path" ] || { log "FAIL: ${path} is not a file"; exit 1; }
		name="$(basename "$path")"
		id="$(printf '%s\n' "$listing" | awk -F'\t' -v n="$name" '$2 == n { print $1; exit }')"

		if [ -z "$id" ]; then
			log "UPLOAD ${name} (not published on ${tag} yet)"
			printf '%s\n' "$name" >> "$plan"
			to_upload=$((to_upload + 1))
			continue
		fi

		"$GH_BIN" api -H "Accept: application/octet-stream" "/repos/${repo}/releases/assets/${id}" > "$tmp_dir/published"
		local_hash="$(sha256sum "$path" | awk '{print $1}')"
		remote_hash="$(sha256sum "$tmp_dir/published" | awk '{print $1}')"
		if [ "$local_hash" = "$remote_hash" ]; then
			log "SKIP ${name} (already published with identical bytes)"
			continue
		fi
		log "FAIL: immutable release asset mismatch for ${name} on ${tag}: published=${remote_hash} rebuild=${local_hash}"
		log "published assets are immutable - publish the next version instead of rewriting ${tag}"
		exit 1
	done

	if [ "$to_upload" -eq 0 ]; then
		log "nothing to upload: every file is already published byte-identically"
	else
		log "${to_upload} file(s) to upload: $(tr '\n' ' ' < "$plan")"
	fi
}

verify_sums() {
	local repo="$1" tag="$2" file="$3"
	[ -f "$file" ] || {
		log "FAIL: ${file} is not a file"
		exit 1
	}

	local release_json
	if ! release_json="$("$GH_BIN" api "repos/${repo}/releases/tags/${tag}")"; then
		log "FAIL: cannot read the release ${tag} in ${repo}"
		exit 1
	fi
	local listing
	listing="$(printf '%s' "$release_json" | "$(python_bin)" -c '
import json, sys
release = json.load(sys.stdin)
for asset in release.get("assets") or []:
    print("%s\t%s" % (asset.get("id"), asset.get("name")))
')"

	tmp_dir="$(mktemp -d)"
	trap 'rm -rf "${tmp_dir:-}"' EXIT

	local checked=0 failures=0 expected name id actual
	while read -r expected name; do
		[ -n "${name:-}" ] || continue
		# coreutils on MSYS marks binary mode with a leading '*'; accept both forms.
		name="${name#\*}"
		id="$(printf '%s\n' "$listing" | awk -F'\t' -v n="$name" '$2 == n { print $1; exit }')"
		if [ -z "$id" ]; then
			log "FAIL: ${file} lists ${name}, which is not published on ${tag}"
			failures=$((failures + 1))
			continue
		fi
		"$GH_BIN" api -H "Accept: application/octet-stream" "/repos/${repo}/releases/assets/${id}" > "$tmp_dir/asset"
		actual="$(sha256sum "$tmp_dir/asset" | awk '{print $1}')"
		checked=$((checked + 1))
		if [ "$actual" != "$expected" ]; then
			log "FAIL: published ${name} on ${tag} hashes ${actual}, but ${file} claims ${expected}"
			failures=$((failures + 1))
		fi
	done < "$file"

	if [ "$failures" -ne 0 ]; then
		log "FAIL: ${file} does not describe the published assets of ${tag}"
		exit 1
	fi
	if [ "$checked" -eq 0 ]; then
		log "FAIL: ${file} lists no assets"
		exit 1
	fi
	log "OK: ${file} matches ${checked} published asset(s) of ${tag}"
}

image() {
	local fixed="$1"
	local liveness="${2:-}"

	if "$DOCKER_BIN" buildx imagetools inspect "$fixed" >/dev/null 2>&1; then
		log "FAIL: immutable image tag ${fixed} already exists in the registry"
		log "a published version tag is never re-pointed - publish the next version instead"
		exit 1
	fi

	if [ -n "$liveness" ] && ! "$DOCKER_BIN" buildx imagetools inspect "$liveness" >/dev/null 2>&1; then
		log "FAIL: cannot reach the registry (neither ${fixed} nor ${liveness} could be inspected)"
		log "this is an infrastructure problem, not an immutability decision - refusing to guess"
		exit 1
	fi

	log "OK: ${fixed} does not exist yet and may be published"
}

main() {
	local command="${1:-}"
	[ -n "$command" ] || usage
	shift
	case "$command" in
	assets) [ "$#" -ge 3 ] || usage; assets "$@" ;;
	verify-sums) [ "$#" -ge 3 ] || usage; verify_sums "$@" ;;
	image) [ "$#" -ge 1 ] || usage; image "$@" ;;
	*) usage ;;
	esac
}

main "$@"
