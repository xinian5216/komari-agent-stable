#!/usr/bin/env bash
# Supply chain gates for the agent installers and the migration script:
#
#   * install.sh: a correct checksum installs; a wrong checksum, a missing
#     checksum and a broken SHA256 tool all refuse to install and leave an
#     existing agent, unit and service untouched;
#   * migrate-komari-agent.sh: a wrong or missing checksum stops before the
#     service is touched (old binary hash, ExecStart and service state intact);
#   * the release workflows keep their required immutability properties.
#
# Everything runs against a local HTTP "release server", so no network, no
# GitHub and no registry are involved. Must run as root (systemd paths).
set -uo pipefail

unset KOMARI_AGENT_REMOTE_CONTROL

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
SERVICE="komari-agent-sctest"
UNIT="/etc/systemd/system/${SERVICE}.service"
TARGET_DIR="${WORK}/opt/komari"
AGENT_PATH="${TARGET_DIR}/agent"
SYSTEMCTL_LOG="${WORK}/systemctl.log"
MIGRATE_DIR="/opt/komari"
MIGRATE_BINARY="${MIGRATE_DIR}/agent"
MIGRATE_DIR_PREEXISTED=0
[ -e "${MIGRATE_DIR}" ] && MIGRATE_DIR_PREEXISTED=1
SERVER_PIDS=""
SERVER_PORT=""
FAILED=0
SHA256SUM_BIN="$(command -v sha256sum)"

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=1; }
step() { printf '==> %s\n' "$1"; }

cleanup() {
    local pid
    for pid in ${SERVER_PIDS}; do kill "${pid}" 2>/dev/null; done
    rm -f "${UNIT}"
    rm -rf "${WORK}"
    if [ "${MIGRATE_DIR_PREEXISTED}" -eq 0 ]; then
        rm -rf "${MIGRATE_DIR}"
    fi
}
trap cleanup EXIT

mkdir -p "${WORK}/bin"
# The systemctl stub records every call, so a test can assert that the service
# was never stopped.
cat > "${WORK}/bin/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "${SYSTEMCTL_LOG}"
exit 0
STUB
chmod +x "${WORK}/bin/systemctl"
export PATH="${WORK}/bin:${PATH}"

if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
else
    TIMEOUT_CMD=""
fi

write_fake_binary() { # <path>
    {
        printf '#!/bin/sh\n'
        printf 'echo "komari-agent version 9.9.9"\n'
        printf 'exit 0\n'
    } > "$1"
    chmod +x "$1"
}

start_server() { # <root-dir>; sets SERVER_PORT
    local root="$1" port
    port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    ( cd "${root}" && exec python3 -m http.server "${port}" --bind 127.0.0.1 >/dev/null 2>&1 ) &
    SERVER_PIDS="${SERVER_PIDS} $!"
    sleep 1
    SERVER_PORT="${port}"
}

run_installer() {
    # stdin closed and bounded: a prompt or a stall fails fast instead of hanging
    ${TIMEOUT_CMD} 180 bash "${REPO_ROOT}/install.sh" \
        --install-dir "${TARGET_DIR}" \
        --install-service-name "${SERVICE}" \
        --install-version "$1" \
        --install-no-mirror </dev/null 2>&1
}

exec_start_line() {
    [ -f "${UNIT}" ] || { printf ''; return; }
    sed -n 's/^ExecStart=//p' "${UNIT}" | head -1
}

write_unit() { # <args>
    cat > "${UNIT}" <<EOF
[Unit]
Description=Komari Agent Service
[Service]
Type=simple
Restart=always
User=root
ExecStart=${AGENT_PATH} $1
[Install]
WantedBy=multi-user.target
EOF
}

write_legacy_agent() { # <path>
    {
        printf '#!/bin/sh\n'
        printf 'echo "komari-agent version 1.0.0"\n'
        printf 'exit 0\n'
    } > "$1"
    chmod +x "$1"
}

# --------------------------------------------------------------- release tree

SERVE_ROOT="${WORK}/serve"
BASE_PATH="${SERVE_ROOT}/xinian5216/komari-agent-stable/releases/download"

make_release() { # <version> <mode: good|badhash|nosums|badsus|fallback>
    local version="$1" mode="$2" dir="${BASE_PATH}/$1" asset="komari-agent-linux-amd64"
    mkdir -p "${dir}"
    write_fake_binary "${dir}/${asset}"
    local sum
    sum="$("${SHA256SUM_BIN}" "${dir}/${asset}" | awk '{print $1}')"

    case "${mode}" in
        good)
            printf '%s\n' "${sum}" > "${dir}/${asset}.sha256"
            printf '%s  %s\n' "${sum}" "${asset}" > "${dir}/SHA256SUMS"
            ;;
        badhash)
            printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000" > "${dir}/${asset}.sha256"
            printf '%s  %s\n' "1111111111111111111111111111111111111111111111111111111111111111" "${asset}" > "${dir}/SHA256SUMS"
            ;;
        nosums)
            : # no checksum assets at all
            ;;
        badsums)
            # valid per-asset file, but SHA256SUMS lists a wrong digest
            printf '%s\n' "${sum}" > "${dir}/${asset}.sha256"
            printf '%s  %s\n' "2222222222222222222222222222222222222222222222222222222222222222" "${asset}" > "${dir}/SHA256SUMS"
            ;;
        fallback)
            # malformed per-asset file, correct SHA256SUMS: the fallback must win
            printf 'not-a-checksum\n' > "${dir}/${asset}.sha256"
            printf '%s  %s\n' "${sum}" "${asset}" > "${dir}/SHA256SUMS"
            ;;
    esac
    printf '%s' "${sum}"
}

GOOD_SUM="$(make_release vGOOD good)"
make_release vBADHASH badhash >/dev/null
make_release vNOSUMS nosums >/dev/null
make_release vBADSUMS badsums >/dev/null
FALLBACK_SUM="$(make_release vFALLBACK fallback)"
start_server "${SERVE_ROOT}"

export KOMARI_AGENT_RELEASE_BASE="http://127.0.0.1:${SERVER_PORT}"
export KOMARI_AGENT_API_BASE="http://127.0.0.1:${SERVER_PORT}/api"

printf '==> supply chain regression tests\n'

# ------------------------------------------------- 1. install: correct checksum

seed_install() { # <version-arg> ; writes an existing agent + unit first
    mkdir -p "${TARGET_DIR}"
    write_legacy_agent "${AGENT_PATH}"
    write_unit "--endpoint http://example.invalid --token secret-token --disable-web-ssh"
}

step "1. install.sh accepts a binary whose checksum matches"
rm -f "${UNIT}"; rm -rf "${TARGET_DIR}"
out="$(run_installer vGOOD)"
if [ -f "${AGENT_PATH}" ] && [ "$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')" = "${GOOD_SUM}" ]; then
    pass "the verified binary was installed"
else
    fail "install.sh did not install the verified binary: ${out}"
fi
case "${out}" in
    *"Checksum verified"*) pass "the installer reports the verification" ;;
    *) fail "the installer did not report the verification" ;;
esac

step "2. the checksum fallback to SHA256SUMS works"
rm -f "${UNIT}"; rm -rf "${TARGET_DIR}"
out="$(run_installer vFALLBACK)"
if [ -f "${AGENT_PATH}" ] && [ "$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')" = "${FALLBACK_SUM}" ]; then
    pass "a malformed per-asset file falls back to SHA256SUMS"
else
    fail "the SHA256SUMS fallback did not install: ${out}"
fi

# ------------------------------------------------ 3. install: failing checksums

install_must_refuse() { # <version> <label>
    rm -f "${UNIT}"; rm -rf "${TARGET_DIR}"
    seed_install
    local before_unit before_binary out
    before_unit="$(exec_start_line)"
    before_binary="$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')"

    out="$(run_installer "$1")"
    local status=$?

    if [ "${status}" -ne 0 ]; then pass "$2: the installer exits non-zero"; else fail "$2: the installer exited 0"; fi
    if [ "$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')" = "${before_binary}" ]; then
        pass "$2: the existing binary is byte-identical"
    else
        fail "$2: the existing binary was modified"
    fi
    if [ "$(exec_start_line)" = "${before_unit}" ]; then
        pass "$2: ExecStart is unchanged"
    else
        fail "$2: ExecStart changed"
    fi
    case "${out}" in
        *"Nothing was installed"*) pass "$2: the installer explains that nothing was installed" ;;
        *)
            fail "$2: the installer did not explain the refusal"
            printf '%s
' "${out}" | sed 's/^/       | /' | tail -12
            ;;
    esac
}

step "3. install.sh refuses a mismatching checksum"
install_must_refuse vBADHASH "wrong checksum"

step "4. install.sh refuses a release without any checksum asset"
install_must_refuse vNOSUMS "missing checksum"

# ------------------------------------------------------ 5. install: no sha256 tool

step "5. install.sh refuses to install when no SHA256 tool works"
rm -f "${UNIT}"; rm -rf "${TARGET_DIR}"
seed_install
before_binary="$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')"
mkdir -p "${WORK}/bintools"
for tool in sha256sum shasum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "${WORK}/bintools/${tool}"
    chmod +x "${WORK}/bintools/${tool}"
done
out="$(PATH="${WORK}/bintools:${PATH}" run_installer vGOOD)"
status=$?
if [ "${status}" -ne 0 ]; then pass "the installer exits non-zero"; else fail "the installer exited 0 without a checksum tool"; fi
if [ "$("${SHA256SUM_BIN}" "${AGENT_PATH}" | awk '{print $1}')" = "${before_binary}" ]; then
    pass "the existing binary is byte-identical"
else
    fail "the existing binary was modified"
fi
case "${out}" in
    *"SHA256 tool"*) pass "the failure names the missing SHA256 tool" ;;
    *)
        fail "the failure does not name the missing SHA256 tool"
        printf '%s
' "${out}" | sed 's/^/       | /' | tail -12
        ;;
esac

# ------------------------------------------------------------ 6. migration

migrate_run() { # <version>
    ${TIMEOUT_CMD} 180 env \
        KOMARI_AGENT_SERVICE="${SERVICE}" \
        KOMARI_TARGET_VERSION="$1" \
        bash "${REPO_ROOT}/migrate-komari-agent.sh" --yes </dev/null 2>&1
}

seed_migration() {
    rm -f "${UNIT}"
    mkdir -p "${MIGRATE_DIR}"
    write_legacy_agent "${MIGRATE_BINARY}"
    write_unit "--endpoint http://example.invalid --token secret-token --disable-web-ssh"
    : > "${SYSTEMCTL_LOG}"
}

migration_must_not_touch_anything() { # <version> <label>
    seed_migration
    local before_unit before_binary out status
    before_unit="$(exec_start_line)"
    before_binary="$("${SHA256SUM_BIN}" "${MIGRATE_BINARY}" | awk '{print $1}')"

    out="$(migrate_run "$1")"
    status=$?

    if [ "${status}" -ne 0 ]; then pass "$2: the migration exits non-zero"; else fail "$2: the migration exited 0"; fi
    if [ "$("${SHA256SUM_BIN}" "${MIGRATE_BINARY}" | awk '{print $1}')" = "${before_binary}" ]; then
        pass "$2: the old binary is byte-identical"
    else
        fail "$2: the old binary was replaced"
    fi
    if [ "$(exec_start_line)" = "${before_unit}" ]; then
        pass "$2: ExecStart is unchanged"
    else
        fail "$2: ExecStart changed"
    fi
    if grep -q "^stop" "${SYSTEMCTL_LOG}" 2>/dev/null; then
        fail "$2: the service was stopped"
    else
        pass "$2: the service was never stopped"
    fi
}

step "6. migration refuses a mismatching checksum without touching anything"
migration_must_not_touch_anything vBADHASH "migration wrong checksum"

step "7. migration refuses a release without any checksum asset"
migration_must_not_touch_anything vNOSUMS "migration missing checksum"

step "8. migration succeeds with a correct checksum"
seed_migration
before_unit="$(exec_start_line)"
out="$(migrate_run vGOOD)"
status=$?
if [ "${status}" -eq 0 ]; then pass "the migration exits 0"; else fail "the migration failed: ${out}"; fi
if [ "$("${SHA256SUM_BIN}" "${MIGRATE_BINARY}" | awk '{print $1}')" = "${GOOD_SUM}" ]; then
    pass "the verified binary replaced the old one"
else
    fail "the binary was not replaced with the published build"
fi
if [ "$(exec_start_line)" = "${before_unit}" ]; then
    pass "ExecStart is still unchanged"
else
    fail "ExecStart changed"
fi

# ------------------------------------------------- 9. workflow properties

step "9. release workflows keep the required immutability properties"

check_file_contains() { # <file> <pattern> <label>
    if grep -q -- "$2" "$1"; then pass "$3"; else fail "$3"; fi
}
check_file_absent() { # <file> <pattern> <label>
    if grep -q -- "$2" "$1"; then fail "$3"; else pass "$3"; fi
}

RELEASE_YML="${REPO_ROOT}/.github/workflows/release.yml"
DOCKER_YML="${REPO_ROOT}/.github/workflows/release-docker.yml"
SNAPSHOT_YML="${REPO_ROOT}/.github/workflows/snapshot.yml"
GUARD="${REPO_ROOT}/.github/scripts/release-guard.sh"

check_file_absent "${RELEASE_YML}" "\-\-clobber" "release.yml never clobbers release assets"
check_file_contains "${RELEASE_YML}" 'release-guard.sh" assets' "release.yml uploads binaries through the guard"
check_file_contains "${RELEASE_YML}" "gh release download" "release.yml derives checksums from the published binaries"
check_file_contains "${RELEASE_YML}" "verify-sums" "release.yml verifies the checksums against the published release"
check_file_contains "${RELEASE_YML}" "Checkout the released tag" "release.yml builds the released tag"
check_file_contains "${DOCKER_YML}" "ref: \${{ steps.source.outputs.tag }}" "release-docker.yml checks out the release tag"
check_file_contains "${DOCKER_YML}" "is not the release tag" "release-docker.yml fails when the checkout is not the tag"
check_file_contains "${DOCKER_YML}" "release-guard.sh\" image" "release-docker.yml guards the fixed image tag"
check_file_contains "${DOCKER_YML}" 'VERSION="\${TAG#v}"' "release-docker.yml compiles the version without the v prefix"
check_file_contains "${SNAPSHOT_YML}" "sha256" "snapshot.yml publishes checksums for the snapshot track"
check_file_contains "${GUARD}" "immutable release asset mismatch" "the guard refuses to rewrite a published asset"

if [ "${FAILED}" -eq 0 ]; then
    printf 'RESULT: supply chain regression tests passed\n'
    exit 0
fi
printf 'RESULT: supply chain regression tests FAILED\n' >&2
exit 1
