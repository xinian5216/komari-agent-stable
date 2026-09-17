package cmd

import (
	"bytes"
	"log"
	"strings"
	"testing"

	pkg_flags "github.com/komari-monitor/komari-agent/cmd/flags"
)

func TestSecurityWarningMentionsElevatedPrivileges(t *testing.T) {
	standard := securityWarning{PanelHost: "panel.example.com", RunAsUser: "komari", Elevated: false}
	if strings.Contains(standard.message(), warningElevatedNote) {
		t.Fatal("standard privilege warning mentions elevated privileges")
	}
	if !strings.Contains(standard.message(), "can execute commands and read or modify files") {
		t.Fatalf("unexpected warning text: %q", standard.message())
	}

	elevated := standard
	elevated.Elevated = true
	message := elevated.message()
	if !strings.Contains(message, warningElevatedNote) {
		t.Fatalf("elevated warning is missing the privilege note: %q", message)
	}
	if !strings.HasSuffix(message, warningUninstallURL) {
		t.Fatalf("elevated warning broke the message layout: %q", message)
	}
}

func TestLogRemoteControlStatusReportsTheEffectiveMode(t *testing.T) {
	original := pkg_flags.GlobalConfig.DisableWebSsh
	t.Cleanup(func() { pkg_flags.GlobalConfig.DisableWebSsh = original })

	var buffer bytes.Buffer
	previousWriter := log.Writer()
	log.SetOutput(&buffer)
	t.Cleanup(func() { log.SetOutput(previousWriter) })

	pkg_flags.GlobalConfig.DisableWebSsh = true
	logRemoteControlStatus()
	if !strings.Contains(buffer.String(), "Remote control: disabled (monitoring only)") {
		t.Fatalf("disabled agent logged %q", buffer.String())
	}

	buffer.Reset()
	pkg_flags.GlobalConfig.DisableWebSsh = false
	logRemoteControlStatus()
	if !strings.Contains(buffer.String(), "Remote control: enabled") {
		t.Fatalf("enabled agent logged %q", buffer.String())
	}
}
