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

func captureLegacyRejectionServer(t *testing.T) (<-chan v2.Request, func()) {
	t.Helper()
	requests := make(chan v2.Request, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req v2.Request
		if err := json.Unmarshal(body, &req); err == nil {
			requests <- req
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{}}`))
	}))
	originalEndpoint, originalToken := pkg_flags.GlobalConfig.Endpoint, pkg_flags.GlobalConfig.Token
	originalCompression := pkg_flags.GlobalConfig.DisableCompression
	pkg_flags.GlobalConfig.Endpoint = srv.URL
	pkg_flags.GlobalConfig.Token = "test-token"
	pkg_flags.GlobalConfig.DisableCompression = true
	cleanup := func() {
		pkg_flags.GlobalConfig.Endpoint = originalEndpoint
		pkg_flags.GlobalConfig.Token = originalToken
		pkg_flags.GlobalConfig.DisableCompression = originalCompression
		srv.Close()
	}
	return requests, cleanup
}

func TestLegacyExecRequestIsRejectedWithoutExecution(t *testing.T) {
	requests, cleanup := captureLegacyRejectionServer(t)
	defer cleanup()
	if handled := processV2Event(nil, v2.MethodAgentExec, map[string]interface{}{
		"task_id": "task-id", "command": "touch /tmp/this-must-never-run",
	}, "event-exec"); !handled {
		t.Fatal("legacy exec request was not handled as a rejection")
	}
	select {
	case req := <-requests:
		if req.Method != v2.MethodAgentTaskResult {
			t.Fatalf("method = %q, want task result rejection", req.Method)
		}
		var result v2.TaskResultParams
		if err := v2.BindParams(req.Params, &result); err != nil {
			t.Fatal(err)
		}
		if result.ExitCode != -1 || !strings.Contains(result.Result, "method not supported") {
			t.Fatalf("unexpected exec rejection: %+v", result)
		}
	case <-timeAfterSeconds(5):
		t.Fatal("no exec rejection was uploaded")
	}
}

func TestLegacyFileRequestIsRejectedWithoutFilesystemAccess(t *testing.T) {
	requests, cleanup := captureLegacyRejectionServer(t)
	defer cleanup()
	if handled := processV2Event(nil, v2.MethodAgentFile, map[string]interface{}{
		"uuid": "node-id", "request_id": "request-id", "op": "delete",
		"args": map[string]interface{}{"path": "/"},
	}, "event-file"); !handled {
		t.Fatal("legacy file request was not handled as a rejection")
	}
	select {
	case req := <-requests:
		if req.Method != v2.MethodAgentFileResult {
			t.Fatalf("method = %q, want file result rejection", req.Method)
		}
		var result v2.FileResult
		if err := v2.BindParams(req.Params, &result); err != nil {
			t.Fatal(err)
		}
		if result.OK || !strings.Contains(result.Error, "method not supported") {
			t.Fatalf("unexpected file rejection: %+v", result)
		}
	case <-timeAfterSeconds(5):
		t.Fatal("no file rejection was uploaded")
	}
}

func TestLegacyTerminalRequestIsAcknowledgedAndRejectedLocally(t *testing.T) {
	if handled := processV2Event(nil, v2.MethodAgentTerminal, map[string]interface{}{
		"request_id": "terminal-id",
	}, "event-terminal"); !handled {
		t.Fatal("legacy terminal request was not handled as a fail-closed rejection")
	}
}
