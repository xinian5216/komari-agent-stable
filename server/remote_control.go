package server

import (
	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

// RemoteControlDisabled reports whether the operator disabled remote control
// (command execution, web terminal and file manager) for this agent.
//
// The value is shared by the --disable-web-ssh (legacy name) and
// --disable-remote-control flags, so both spellings keep working.
func RemoteControlDisabled() bool {
	return flags.DisableWebSsh
}

// Capabilities returns the capability list advertised to the server.
//
// Remote control disabled agents must not advertise exec/terminal/file: the
// agent still refuses those operations locally (defense in depth), but the
// panel should not offer them in the first place.
func Capabilities() []string {
	if RemoteControlDisabled() {
		return v2.CapabilitiesMonitoringOnly()
	}
	return v2.CapabilitiesAll()
}

// PrivilegeLevel returns the coarse privilege level of the OS account the
// agent runs as. The account name itself never leaves the device.
func PrivilegeLevel() v2.PrivilegeLevel {
	return privilegeLevel()
}

// RunsElevated reports whether the agent runs as root / Administrator / SYSTEM,
// which turns enabled remote control into high-privilege remote control.
func RunsElevated() bool {
	return PrivilegeLevel() == v2.PrivilegeLevelElevated
}
