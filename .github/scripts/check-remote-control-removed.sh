#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "remote-control removal guard: $*" >&2
    exit 1
}

if [ -d terminal ] && [ -n "$(find terminal -type f -print -quit)" ]; then
    fail 'terminal implementation files must stay deleted'
fi

for path in server/files.go server/file_stream.go server/files_unix.go server/files_windows.go; do
    [ ! -e "$path" ] || fail "$path must stay deleted"
done

source_files="$(find server -maxdepth 1 -type f -name '*.go' ! -name '*_test.go' -print)"
if [ -n "$source_files" ] && rg -n 'os/exec|exec\.Command|ExecutionPolicy|/api/clients/(terminal|transfer/)' $source_files; then
    fail 'an executable command, PTY, or file-transfer primitive returned to server/'
fi

if rg -n 'github.com/(UserExistsError/conpty|creack/pty|go-ole/go-ole)|gopkg.in/toast' go.mod; then
    fail 'a removed terminal or desktop-warning dependency returned to go.mod'
fi

if rg -n 'remote_control_choice|RemoteControlChoice|remote_control_decision|RemoteControlDecision|apply_remote_control_args|Get-ExistingRemoteControlState' install.sh install.ps1; then
    fail 'an installer path can still select a remote-control mode'
fi

if rg -n '"(exec|terminal|file)"' protocol/v2/capabilities.go; then
    fail 'a removed remote-control capability returned'
fi

rg -q 'method not supported: remote control is not compiled into this build' server/remote_control.go \
    || fail 'the fail-closed legacy rejection is missing'
rg -q 'MarkHidden\("disable-web-ssh"\)' cmd/root.go \
    || fail 'the legacy --disable-web-ssh compatibility flag is not hidden'
rg -q 'MarkHidden\("disable-remote-control"\)' cmd/root.go \
    || fail 'the legacy --disable-remote-control compatibility flag is not hidden'

echo 'remote-control removal guard: OK'
