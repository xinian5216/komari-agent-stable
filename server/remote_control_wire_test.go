package server

import (
	"encoding/json"
	"testing"

	monitoring "github.com/komari-monitor/komari-agent/monitoring"
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

type reportEnvelope struct {
	Method string `json:"method"`
	Params struct {
		Report map[string]interface{} `json:"report"`
	} `json:"params"`
}

func TestReportEnvelopeCarriesOnlyMonitoringCapabilities(t *testing.T) {
	payload := v2.BuildReportPayload(reportPayload(monitoring.GenerateReport()))
	var envelope reportEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("report envelope is not valid JSON: %v", err)
	}
	if envelope.Method != v2.MethodAgentReport {
		t.Fatalf("method = %q, want %q", envelope.Method, v2.MethodAgentReport)
	}
	for _, metric := range []string{"cpu", "ram", "disk", "load", "network", "uptime"} {
		if _, ok := envelope.Params.Report[metric]; !ok {
			t.Fatalf("metric %q was lost", metric)
		}
	}
	raw, ok := envelope.Params.Report["capabilities"].([]interface{})
	if !ok || len(raw) != 3 {
		t.Fatalf("capabilities = %v, want ping/message/event", raw)
	}
	want := []string{"ping", "message", "event"}
	for i, item := range raw {
		if item != want[i] {
			t.Fatalf("capabilities = %v, want %v", raw, want)
		}
	}
}
