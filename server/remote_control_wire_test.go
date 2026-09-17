package server

import (
	"encoding/json"
	"testing"

	monitoring "github.com/komari-monitor/komari-agent/monitoring"
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

// reportEnvelope mirrors the envelope the agent puts on the wire.
type reportEnvelope struct {
	Method string `json:"method"`
	Params struct {
		Report map[string]interface{} `json:"report"`
	} `json:"params"`
}

// TestReportEnvelopeCarriesCapabilities exercises the exact bytes the agent
// sends, end to end: the monitoring report builder, the capability augmentation
// and the JSON-RPC envelope.
func TestReportEnvelopeCarriesCapabilities(t *testing.T) {
	cases := []struct {
		name     string
		disabled bool
		want     []string
	}{
		{"monitoring only", true, []string{"ping", "message", "event"}},
		{"remote control enabled", false, []string{"ping", "message", "event", "exec", "terminal", "file"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setRemoteControlDisabled(t, tc.disabled)

			payload := v2.BuildReportPayload(reportPayload(monitoring.GenerateReport()))

			var envelope reportEnvelope
			if err := json.Unmarshal(payload, &envelope); err != nil {
				t.Fatalf("report envelope is not valid JSON: %v", err)
			}
			if envelope.Method != v2.MethodAgentReport {
				t.Fatalf("method = %q, want %q", envelope.Method, v2.MethodAgentReport)
			}

			report := envelope.Params.Report
			for _, metric := range []string{"cpu", "ram", "disk", "load", "network", "uptime"} {
				if _, ok := report[metric]; !ok {
					t.Fatalf("metric %q was lost from the report: %v", metric, report)
				}
			}

			raw, ok := report["capabilities"].([]interface{})
			if !ok {
				t.Fatalf("capabilities missing from the report: %v", report)
			}
			got := make([]string, 0, len(raw))
			for _, item := range raw {
				text, ok := item.(string)
				if !ok {
					t.Fatalf("capability %v is not a string", item)
				}
				got = append(got, text)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("capabilities = %v, want %v", got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Fatalf("capabilities = %v, want %v", got, tc.want)
				}
			}

			privilege, ok := report["privilege_level"].(string)
			if !ok {
				t.Fatalf("privilege level missing from the report: %v", report)
			}
			switch privilege {
			case "elevated", "standard", "unknown":
			default:
				t.Fatalf("privilege level = %q", privilege)
			}
		})
	}
}
