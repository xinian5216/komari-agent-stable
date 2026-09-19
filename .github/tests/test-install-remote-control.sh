#!/usr/bin/env bash
# Monitoring-only installer policy and legacy argument compatibility.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
SERVICE="komari-agent-monitoring-only-test"
UNIT="/etc/systemd/system/${SERVICE}.service"
TARGET_DIR="${WORK}/opt/komari"
FAILED=0
SERVER_PID=""

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILED=1; }

cleanup() {
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    rm -f "$UNIT"
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "${WORK}/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/bin/systemctl"
chmod +x "${WORK}/bin/systemctl"
export PATH="${WORK}/bin:${PATH}"

SERVE_ROOT="${WORK}/serve"
RELEASE_DIR="${SERVE_ROOT}/xinian5216/komari-agent-stable/releases/download/vTEST"
mkdir -p "$RELEASE_DIR"
cat > "${RELEASE_DIR}/komari-agent-linux-amd64" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "--help" ]; then
    echo 'Usage: komari-agent [flags]'
    exit 0
fi
echo 'remote control is not compiled into this build'
BIN
chmod +x "${RELEASE_DIR}/komari-agent-linux-amd64"
(
    cd "$RELEASE_DIR" || exit 1
    sha256sum komari-agent-linux-amd64 > SHA256SUMS
    awk '{print $1}' SHA256SUMS > komari-agent-linux-amd64.sha256
)

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
(cd "$SERVE_ROOT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
sleep 1

export KOMARI_AGENT_RELEASE_BASE="http://127.0.0.1:${PORT}"
export KOMARI_AGENT_REPO_OWNER="xinian5216"
export KOMARI_AGENT_REPO_NAME="komari-agent-stable"

run_installer() {
    timeout 180 bash "${REPO_ROOT}/install.sh" \
        --install-dir "$TARGET_DIR" \
        --install-service-name "$SERVICE" \
        --install-version vTEST \
        --install-no-mirror "$@" </dev/null 2>&1
}

reset_install() {
    rm -f "$UNIT"
    rm -rf "$TARGET_DIR"
}

exec_start_line() {
    sed -n 's/^ExecStart=//p' "$UNIT" 2>/dev/null | head -1
}

echo '==> monitoring-only installer policy tests'

reset_install
out="$(run_installer)"
line="$(exec_start_line)"
case "$line" in
    *--disable-web-ssh*|*--disable-remote-control*)
        fail "fresh install wrote a redundant legacy remote-control flag: $line" ;;
    *) pass 'fresh install does not write legacy remote-control flags' ;;
esac
case "$out" in
    *'remote control is not compiled into this build'*) pass 'installer reports the monitoring-only build' ;;
    *) fail 'installer did not report the monitoring-only build' ;;
esac

reset_install
out="$(run_installer --enable-remote-control)"
rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$UNIT" ] && [ ! -e "${TARGET_DIR}/agent" ]; then
    pass '--enable-remote-control fails before installation'
else
    fail '--enable-remote-control was accepted or changed the system'
fi
case "$out" in
    *'not compiled into this build'*) pass 'enable refusal explains the security boundary' ;;
    *) fail 'enable refusal message is missing' ;;
esac

reset_install
out="$(KOMARI_AGENT_REMOTE_CONTROL=1 run_installer)"
line="$(exec_start_line)"
case "$line" in
    *--disable-web-ssh*|*--disable-remote-control*) fail 'legacy environment variable changed service arguments' ;;
    *) pass 'legacy environment variable cannot enable remote control' ;;
esac
case "$out" in
    *'deprecated and ignored'*) pass 'legacy environment variable emits a deprecation warning' ;;
    *) fail 'legacy environment variable warning is missing' ;;
esac

reset_install
out="$(run_installer --disable-remote-control)"
line="$(exec_start_line)"
case "$line" in
    *--disable-web-ssh*|*--disable-remote-control*) fail 'deprecated installer flag was persisted' ;;
    *) pass 'deprecated installer flag is accepted as a no-op' ;;
esac
case "$out" in
    *'deprecated no-op'*) pass 'deprecated installer flag emits a warning' ;;
    *) fail 'deprecated installer flag warning is missing' ;;
esac

echo
if [ "$FAILED" -ne 0 ]; then
    echo 'RESULT: monitoring-only installer policy tests FAILED'
    exit 1
fi
echo 'RESULT: monitoring-only installer policy tests passed'
