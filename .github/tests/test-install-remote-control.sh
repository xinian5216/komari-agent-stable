#!/usr/bin/env bash
# Verifies the remote control policy of install.sh and migrate-komari-agent.sh
# without touching the network:
#
#   * new installations default to monitoring only
#   * --enable-remote-control / --disable-remote-control and
#     KOMARI_AGENT_REMOTE_CONTROL=1|0 are honored
#   * reinstalling keeps the existing service's remote control state
#   * an existing service whose state cannot be read stops the installer
#   * the flag spelling falls back to --disable-web-ssh for older binaries
#   * migrate-komari-agent.sh keeps the existing start arguments untouched
#
# Runs as root on a Linux host (a CI runner or a container). Only a stub
# systemctl is used, so nothing is actually started.
set -uo pipefail

# The installer reads this variable; make sure the test controls it explicitly.
unset KOMARI_AGENT_REMOTE_CONTROL

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
SERVICE="komari-agent-rctest"
UNIT="/etc/systemd/system/${SERVICE}.service"
TARGET_DIR="${WORK}/opt/komari"
AGENT_PATH="${TARGET_DIR}/agent"
FAILED=0
SERVER_PIDS=""

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=1; }
step() { printf '\n==> %s\n' "$1"; }

cleanup() {
    for pid in ${SERVER_PIDS}; do kill "${pid}" 2>/dev/null; done
    rm -f "${UNIT}"
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- stub systemctl ---------------------------------------------------------
mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/systemctl"
chmod +x "${WORK}/bin/systemctl"
export PATH="${WORK}/bin:${PATH}"

# --- fake release server ----------------------------------------------------
# Two builds: the current one advertises the new alias, the legacy one only
# knows --disable-web-ssh.
write_fake_binary() {
    local dest="$1" with_alias="$2"
    mkdir -p "$(dirname "${dest}")"
    {
        printf '#!/bin/sh\n'
        printf 'if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then\n'
        printf '  echo "Usage: komari-agent [flags]"\n'
        printf '  echo "      --disable-web-ssh"\n'
        [ "${with_alias}" = "yes" ] && printf '  echo "      --disable-remote-control"\n'
        printf '  exit 0\n'
        printf 'fi\n'
        printf 'echo "komari-agent version 9.9.9"\n'
        printf 'exit 0\n'
    } > "${dest}"
    chmod +x "${dest}"
}

start_server() {
    local root="$1"
    local port
    port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
    (cd "${root}" && python3 -m http.server "${port}" --bind 127.0.0.1 >/dev/null 2>&1) &
    SERVER_PIDS="${SERVER_PIDS} $!"
    sleep 1
    printf '%s' "${port}"
}

SERVE_ROOT="${WORK}/serve"
SERVE="${SERVE_ROOT}/xinian5216/komari-agent-stable/releases/download/vTEST"
write_fake_binary "${SERVE}/komari-agent-linux-amd64" yes
(cd "${SERVE}" && sha256sum komari-agent-linux-amd64 > komari-agent-linux-amd64.sha256 && cp komari-agent-linux-amd64.sha256 SHA256SUMS)
PORT="$(start_server "${SERVE_ROOT}")"

export KOMARI_AGENT_RELEASE_BASE="http://127.0.0.1:${PORT}"
export KOMARI_AGENT_REPO_OWNER="xinian5216"
export KOMARI_AGENT_REPO_NAME="komari-agent-stable"

# A missing timeout(1) must not be mistaken for a product failure.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
else
    TIMEOUT_CMD=""
fi

run_installer() {
    # stdin is closed so that any interactive prompt fails fast instead of
    # hanging the job, and the whole run is bounded.
    ${TIMEOUT_CMD} 180 bash "${REPO_ROOT}/install.sh" \
        --install-dir "${TARGET_DIR}" \
        --install-service-name "${SERVICE}" \
        --install-version vTEST \
        --install-no-mirror "$@" </dev/null 2>&1
    status=$?
    if [ "${status}" -eq 124 ]; then
        fail "installer timed out: install.sh $*"
    fi
    return "${status}"
}

exec_start_line() { sed -n 's/^ExecStart=//p' "${UNIT}" 2>/dev/null | head -1; }

has_disable_flag() {
    case "$1" in
        *--disable-web-ssh*|*--disable-remote-control*) return 0 ;;
        *) return 1 ;;
    esac
}

write_legacy_unit() {
    local extra="$1"
    cat > "${UNIT}" <<EOF
[Unit]
Description=Komari Agent Service
[Service]
Type=simple
ExecStart=${AGENT_PATH} --endpoint https://panel.example.com --token secret-token ${extra}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
}

reset_install() {
    rm -f "${UNIT}"
    rm -rf "${TARGET_DIR}"
}

echo "==> remote control installer policy tests"

# 1. Fresh installation defaults to monitoring only.
step "1. fresh install (no options) -> monitoring only"
reset_install
out="$(run_installer)"
line="$(exec_start_line)"
if [[ "${line}" == *--disable-remote-control* ]]; then
    pass "default install writes --disable-remote-control"
elif has_disable_flag "${line}"; then
    fail "default install used the legacy flag instead of the preferred alias: ${line}"
else
    fail "default install did not disable remote control: ${line}"
fi
case "${out}" in
    *"default for new installations"*) pass "installer reports the new-installation default" ;;
    *) fail "installer did not report the default source" ;;
esac
case "${out}" in
    *"Remote control: disabled"*) pass "installer reports the effective mode" ;;
    *) fail "installer did not report the effective mode" ;;
esac

# 2. Explicit opt-in enables remote control.
step "2. fresh install with --enable-remote-control -> remote control on"
reset_install
run_installer --enable-remote-control >/dev/null
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    fail "explicit opt-in still produced a disabling flag: ${line}"
else
    pass "explicit opt-in keeps remote control enabled"
fi

# 3. Reinstalling keeps a disabled installation disabled.
step "3. reinstall over a disabled installation -> still disabled"
reset_install
run_installer >/dev/null
out="$(run_installer)"
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    pass "reinstall kept the disabled state"
else
    fail "reinstall silently enabled remote control: ${line}"
fi
case "${out}" in
    *"kept from the existing service"*) pass "installer reports the preserved state" ;;
    *) fail "installer did not report the preserved state" ;;
esac

# 4. Reinstalling keeps an enabled installation enabled.
step "4. reinstall over an enabled installation -> still enabled"
reset_install
mkdir -p "${TARGET_DIR}"
write_fake_binary "${AGENT_PATH}" yes
write_legacy_unit ""
before_args="$(exec_start_line)"
out="$(run_installer)"
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    fail "reinstall disabled an existing remote-control installation: ${line}"
else
    pass "reinstall kept the enabled state"
fi
case "${out}" in
    *"kept from the existing service"*) pass "installer reports the preserved state" ;;
    *) fail "installer did not report the preserved state" ;;
esac
case "${line}" in
    *"--token secret-token"*) pass "existing ExecStart arguments survive a reinstall" ;;
    *) fail "existing ExecStart arguments were lost: ${line}" ;;
esac

# 5. Unreadable existing service stops the installer instead of guessing.
step "5. unreadable existing service -> explicit choice required"
reset_install
mkdir -p "${TARGET_DIR}"
printf '#!/bin/sh\nexit 0\n' > "${AGENT_PATH}"
chmod +x "${AGENT_PATH}"
cat > "${UNIT}" <<EOF
[Unit]
Description=Unrelated service
[Service]
ExecStart=/usr/bin/something-else --flag
EOF
before="$(cat "${UNIT}")"
out="$(run_installer)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    pass "installer refused to guess (exit ${rc})"
else
    fail "installer continued despite an unreadable existing service"
fi
case "${out}" in
    *"could not be read"*) pass "installer explains why it stopped" ;;
    *) fail "installer did not explain the refusal" ;;
esac
if [ "$(cat "${UNIT}")" = "${before}" ]; then
    pass "existing service definition was left untouched"
else
    fail "existing service definition was modified"
fi
run_installer --disable-remote-control >/dev/null
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    pass "explicit choice unblocks the installation"
else
    fail "explicit choice did not disable remote control: ${line}"
fi

# 6. Environment variable forms.
step "6. KOMARI_AGENT_REMOTE_CONTROL=1|0"
reset_install
KOMARI_AGENT_REMOTE_CONTROL=1 run_installer >/dev/null
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    fail "KOMARI_AGENT_REMOTE_CONTROL=1 produced a disabling flag: ${line}"
else
    pass "KOMARI_AGENT_REMOTE_CONTROL=1 keeps remote control enabled"
fi
reset_install
KOMARI_AGENT_REMOTE_CONTROL=0 run_installer >/dev/null
line="$(exec_start_line)"
if has_disable_flag "${line}"; then
    pass "KOMARI_AGENT_REMOTE_CONTROL=0 disables remote control"
else
    fail "KOMARI_AGENT_REMOTE_CONTROL=0 did not disable remote control"
fi
reset_install
out="$(KOMARI_AGENT_REMOTE_CONTROL=banana run_installer)"
case "${out}" in
    *"Invalid KOMARI_AGENT_REMOTE_CONTROL"*) pass "invalid environment value is rejected" ;;
    *) fail "invalid environment value was accepted" ;;
esac

# 7. Legacy binary without the new alias falls back to --disable-web-ssh.
step "7. legacy binary -> --disable-web-ssh fallback"
reset_install
LEGACY_ROOT="${WORK}/legacy"
LEGACY_SERVE="${LEGACY_ROOT}/xinian5216/komari-agent-stable/releases/download/vTEST"
write_fake_binary "${LEGACY_SERVE}/komari-agent-linux-amd64" no
LEGACY_PORT="$(start_server "${LEGACY_ROOT}")"
KOMARI_AGENT_RELEASE_BASE="http://127.0.0.1:${LEGACY_PORT}" run_installer >/dev/null
line="$(exec_start_line)"
if [[ "${line}" == *--disable-web-ssh* ]]; then
    pass "legacy binary gets the universally supported flag"
else
    fail "legacy binary did not get --disable-web-ssh: ${line}"
fi

# 8. Conflicting options are refused.
step "8. --enable-remote-control with --disable-web-ssh is refused"
reset_install
out="$(run_installer --enable-remote-control --disable-web-ssh)"
case "${out}" in
    *"Conflicting options"*) pass "conflicting options rejected" ;;
    *) fail "conflicting options were accepted" ;;
esac

# 9. Migration keeps the existing start arguments untouched.
step "9. migrate-komari-agent.sh keeps the start arguments"
# migrate-komari-agent.sh operates on the fixed /opt/komari installation path.
reset_install
MIGRATE_DIR="/opt/komari"
MIGRATE_BINARY="${MIGRATE_DIR}/agent"
MIGRATE_DIR_PREEXISTED=0
[ -e "${MIGRATE_DIR}" ] && MIGRATE_DIR_PREEXISTED=1
mkdir -p "${MIGRATE_DIR}"
write_fake_binary "${MIGRATE_BINARY}" yes
cat > "${UNIT}" <<EOF
[Unit]
Description=Komari Agent Service
[Service]
Type=simple
ExecStart=${MIGRATE_BINARY} --endpoint https://panel.example.com --token secret-token --disable-web-ssh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
before_args="$(exec_start_line)"
before_sum="$(sha256sum "${MIGRATE_BINARY}" | awk '{print $1}')"
out="$(${TIMEOUT_CMD} 180 env KOMARI_AGENT_SERVICE="${SERVICE}" KOMARI_TARGET_VERSION=vTEST \
    bash "${REPO_ROOT}/migrate-komari-agent.sh" --yes </dev/null 2>&1)"
after_args="$(exec_start_line)"
after_sum="$(sha256sum "${MIGRATE_BINARY}" | awk '{print $1}')"
if [ "${before_args}" = "${after_args}" ]; then
    pass "ExecStart is unchanged after migration"
else
    fail "migration rewrote ExecStart: '${before_args}' -> '${after_args}'"
fi
case "${before_args}" in
    *"--disable-web-ssh"*) pass "disabled state survives migration (args identical)" ;;
    *) fail "unexpected pre-migration args: ${before_args}" ;;
esac
if [ "${before_sum}" != "${after_sum}" ]; then
    pass "migration actually replaced the binary (the check above is meaningful)"
else
    fail "migration did not run (arguments check would be vacuous): ${out}"
fi
if [ "${MIGRATE_DIR_PREEXISTED}" -eq 0 ]; then
    rm -rf "${MIGRATE_DIR}"
fi

echo
if [ "${FAILED}" -ne 0 ]; then
    echo "RESULT: remote control installer policy tests FAILED"
    exit 1
fi
echo "RESULT: remote control installer policy tests passed"
exit 0
