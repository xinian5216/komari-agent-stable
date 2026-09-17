package server

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

func setRemoteControlDisabled(t *testing.T, disabled bool) {
	t.Helper()
	original := pkg_flags.GlobalConfig.DisableWebSsh
	pkg_flags.GlobalConfig.DisableWebSsh = disabled
	t.Cleanup(func() { pkg_flags.GlobalConfig.DisableWebSsh = original })
}

func TestCapabilitiesFollowRemoteControlFlag(t *testing.T) {
	cases := []struct {
		name     string
		disabled bool
		want     []string
	}{
		{
			name:     "remote control disabled",
			disabled: true,
			want:     []string{"ping", "message", "event"},
		},
		{
			name:     "remote control enabled",
			disabled: false,
			want:     []string{"ping", "message", "event", "exec", "terminal", "file"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setRemoteControlDisabled(t, tc.disabled)
			got := Capabilities()
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("Capabilities() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestCapabilitiesNeverAdvertiseRemoteControlWhenDisabled(t *testing.T) {
	setRemoteControlDisabled(t, true)
	got := strings.Join(Capabilities(), ",")
	for _, forbidden := range []string{v2.CapabilityExec, v2.CapabilityTerminal, v2.CapabilityFile} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("disabled agent still advertises %q in capabilities %q", forbidden, got)
		}
	}
}

func TestCapabilitiesAllKeepsMonitoringCapabilitiesStable(t *testing.T) {
	if got := v2.CapabilitiesAll()[:3]; !reflect.DeepEqual(got, v2.CapabilitiesMonitoringOnly()) {
		t.Fatalf("capability order changed: %v", v2.CapabilitiesAll())
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

func TestRemoteControlDisabledMirrorsFlag(t *testing.T) {
	setRemoteControlDisabled(t, true)
	if !RemoteControlDisabled() {
		t.Fatal("RemoteControlDisabled() = false while --disable-web-ssh is set")
	}
	setRemoteControlDisabled(t, false)
	if RemoteControlDisabled() {
		t.Fatal("RemoteControlDisabled() = true while remote control is enabled")
	}
}

func TestReportPayloadCarriesRemoteControlInfo(t *testing.T) {
	setRemoteControlDisabled(t, true)
	augmented := reportPayload([]byte(`{"cpu":{"usage":1},"uptime":5}`))

	var decoded map[string]interface{}
	if err := json.Unmarshal(augmented, &decoded); err != nil {
		t.Fatalf("report payload is not valid JSON: %v", err)
	}
	if decoded["cpu"] == nil || decoded["uptime"] == nil {
		t.Fatalf("existing report fields were lost: %v", decoded)
	}
	capabilities, ok := decoded["capabilities"].([]interface{})
	if !ok {
		t.Fatalf("capabilities missing from the report: %v", decoded)
	}
	if len(capabilities) != 3 {
		t.Fatalf("disabled agent reported %v", capabilities)
	}
	if _, ok := decoded["privilege_level"].(string); !ok {
		t.Fatalf("privilege level missing from the report: %v", decoded)
	}

	setRemoteControlDisabled(t, false)
	if !strings.Contains(string(reportPayload([]byte(`{}`))), `"exec"`) {
		t.Fatal("enabled agent did not report the exec capability")
	}

	// A malformed report is passed through untouched instead of being dropped.
	const broken = `{not json`
	if got := string(reportPayload([]byte(broken))); got != broken {
		t.Fatalf("malformed report was rewritten: %q", got)
	}
}

// TestBasicInfoPayloadStaysBackwardCompatible guards the contract that broke
// once: released servers map agent.basicInfo straight onto SQL columns, so an
// unknown key makes them fail with "no such column" and the agent stops being
// able to report basic info at all. New fields must go somewhere typed instead
// (see agent.report).
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
			t.Fatalf("agent.basicInfo gained the key %q; released servers reject unknown keys when saving basic info", key)
		}
	}
	for key := range allowed {
		if _, ok := payload[key]; !ok {
			t.Fatalf("agent.basicInfo lost the key %q", key)
		}
	}
}
