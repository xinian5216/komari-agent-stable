package server

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

func TestCapabilitiesAreAlwaysMonitoringOnly(t *testing.T) {
	want := []string{"ping", "message", "event"}
	original := pkg_flags.GlobalConfig.DisableWebSsh
	t.Cleanup(func() { pkg_flags.GlobalConfig.DisableWebSsh = original })
	for _, legacyValue := range []bool{false, true} {
		pkg_flags.GlobalConfig.DisableWebSsh = legacyValue
		if got := Capabilities(); !reflect.DeepEqual(got, want) {
			t.Fatalf("Capabilities() with legacy flag %t = %v, want %v", legacyValue, got, want)
		}
	}
	for _, forbidden := range []string{"exec", "terminal", "file"} {
		if strings.Contains(strings.Join(Capabilities(), ","), forbidden) {
			t.Fatalf("monitoring-only agent advertised %q", forbidden)
		}
	}
}

func TestLegacyRemoteControlMethodsAreRecognizedForRejection(t *testing.T) {
	for _, method := range []string{v2.MethodAgentExec, v2.MethodAgentTerminal, v2.MethodAgentFile} {
		if !isUnsupportedRemoteControlMethod(method) {
			t.Fatalf("legacy method %q is not routed to the fail-closed rejection", method)
		}
	}
	if isUnsupportedRemoteControlMethod(v2.MethodAgentPing) {
		t.Fatal("ping was incorrectly classified as remote control")
	}
}

func TestPrivilegeLevelIsCoarse(t *testing.T) {
	got := PrivilegeLevel()
	switch got {
	case v2.PrivilegeLevelElevated, v2.PrivilegeLevelStandard, v2.PrivilegeLevelUnknown:
	default:
		t.Fatalf("PrivilegeLevel() = %q, want one of elevated/standard/unknown", got)
	}
	if strings.ContainsAny(string(got), `\/:@ `) {
		t.Fatalf("PrivilegeLevel() %q looks like it leaks account details", got)
	}
}

func TestReportPayloadCarriesMonitoringOnlyInfo(t *testing.T) {
	augmented := reportPayload([]byte(`{"cpu":{"usage":1},"uptime":5}`))

	var decoded map[string]interface{}
	if err := json.Unmarshal(augmented, &decoded); err != nil {
		t.Fatalf("report payload is not valid JSON: %v", err)
	}
	if decoded["cpu"] == nil || decoded["uptime"] == nil {
		t.Fatalf("existing report fields were lost: %v", decoded)
	}
	capabilities, ok := decoded["capabilities"].([]interface{})
	if !ok || len(capabilities) != 3 {
		t.Fatalf("capabilities = %v, want ping/message/event", capabilities)
	}
	text := string(augmented)
	for _, forbidden := range []string{`"exec"`, `"terminal"`, `"file"`} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("report advertised removed remote control: %s", augmented)
		}
	}
	if _, ok := decoded["privilege_level"].(string); !ok {
		t.Fatalf("privilege level missing from the report: %v", decoded)
	}

	const broken = `{not json`
	if got := string(reportPayload([]byte(broken))); got != broken {
		t.Fatalf("malformed report was rewritten: %q", got)
	}
}

func TestBasicInfoPayloadStaysBackwardCompatible(t *testing.T) {
	allowed := map[string]bool{
		"cpu_name": true, "cpu_cores": true, "cpu_physical_cores": true,
		"arch": true, "os": true, "kernel_version": true, "ipv4": true,
		"ipv6": true, "mem_total": true, "swap_total": true, "disk_total": true,
		"gpu_name": true, "virtualization": true, "version": true,
	}
	payload := basicInfoPayload()
	for key := range payload {
		if !allowed[key] {
			t.Fatalf("agent.basicInfo gained the key %q", key)
		}
	}
	for key := range allowed {
		if _, ok := payload[key]; !ok {
			t.Fatalf("agent.basicInfo lost the key %q", key)
		}
	}
}
