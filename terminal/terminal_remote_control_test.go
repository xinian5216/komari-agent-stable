package terminal

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
)

func setDisableWebSsh(t *testing.T, disabled bool) {
	t.Helper()
	original := pkg_flags.GlobalConfig.DisableWebSsh
	pkg_flags.GlobalConfig.DisableWebSsh = disabled
	t.Cleanup(func() { pkg_flags.GlobalConfig.DisableWebSsh = original })
}

func openSessionCount() int {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()
	return len(sessions)
}

// TestStartTerminalRefusedWhenRemoteControlDisabled proves that a terminal
// request is answered with the refusal and that no shell session is created.
func TestStartTerminalRefusedWhenRemoteControlDisabled(t *testing.T) {
	setDisableWebSsh(t, true)

	before := openSessionCount()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Upgrade(w, r, nil, 1024, 1024)
		if err != nil {
			return
		}
		StartTerminal(conn, "request-id")
	}))
	defer server.Close()

	conn, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	var received strings.Builder
	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			break
		}
		received.Write(data)
	}

	if !strings.Contains(received.String(), "Web SSH is disabled") {
		t.Fatalf("terminal was not refused: %q", received.String())
	}
	if got := openSessionCount(); got != before {
		t.Fatalf("terminal sessions = %d, want %d (no shell may be spawned while remote control is disabled)", got, before)
	}
}
