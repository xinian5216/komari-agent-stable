package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

func timeAfterSeconds(seconds int) <-chan time.Time {
	return time.After(time.Duration(seconds) * time.Second)
}

// TestExecTaskRefusedWhenRemoteControlDisabled proves the agent execution path
// stops before any command runs and reports the refusal to the server.
func TestExecTaskRefusedWhenRemoteControlDisabled(t *testing.T) {
	type captured struct {
		result   string
		exitCode int
	}

	results := make(chan captured, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &req); err == nil && req.Method == v2.MethodAgentTaskResult {
			var params struct {
				Result   string `json:"result"`
				ExitCode int    `json:"exit_code"`
			}
			if err := json.Unmarshal(req.Params, &params); err == nil {
				results <- captured{result: params.Result, exitCode: params.ExitCode}
			}
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	originalEndpoint, originalToken := pkg_flags.GlobalConfig.Endpoint, pkg_flags.GlobalConfig.Token
	originalCompression := pkg_flags.GlobalConfig.DisableCompression
	pkg_flags.GlobalConfig.Endpoint = srv.URL
	pkg_flags.GlobalConfig.Token = "test-token"
	pkg_flags.GlobalConfig.DisableCompression = true
	t.Cleanup(func() {
		pkg_flags.GlobalConfig.Endpoint = originalEndpoint
		pkg_flags.GlobalConfig.Token = originalToken
		pkg_flags.GlobalConfig.DisableCompression = originalCompression
	})

	setRemoteControlDisabled(t, true)
	NewTask("task-id", "echo this must not run")

	select {
	case got := <-results:
		if !strings.Contains(got.result, "Remote control is disabled") {
			t.Fatalf("task result = %q, want the remote control refusal", got.result)
		}
		if got.exitCode != -1 {
			t.Fatalf("exit code = %d, want -1", got.exitCode)
		}
	case <-timeAfterSeconds(5):
		t.Fatal("no task result was uploaded")
	}
}

// TestExecTaskStillRunsWhenRemoteControlEnabled is the control case: without the
// flag the execution path stays untouched.
func TestExecTaskStillRunsWhenRemoteControlEnabled(t *testing.T) {
	results := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		results <- string(body)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	originalEndpoint, originalToken := pkg_flags.GlobalConfig.Endpoint, pkg_flags.GlobalConfig.Token
	originalCompression := pkg_flags.GlobalConfig.DisableCompression
	pkg_flags.GlobalConfig.Endpoint = srv.URL
	pkg_flags.GlobalConfig.Token = "test-token"
	pkg_flags.GlobalConfig.DisableCompression = true
	t.Cleanup(func() {
		pkg_flags.GlobalConfig.Endpoint = originalEndpoint
		pkg_flags.GlobalConfig.Token = originalToken
		pkg_flags.GlobalConfig.DisableCompression = originalCompression
	})

	setRemoteControlDisabled(t, false)
	NewTask("task-id", "echo hello")

	select {
	case body := <-results:
		if strings.Contains(body, "Remote control is disabled") {
			t.Fatalf("enabled agent refused the task: %s", body)
		}
		if !strings.Contains(body, "hello") {
			t.Fatalf("task output was not reported: %s", body)
		}
	case <-timeAfterSeconds(10):
		t.Fatal("no task result was uploaded")
	}
}
