package server

import (
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
