package v2

// Capability names advertised by the agent to the server.
//
// The list is the single source of truth for what the panel may ask this agent
// to do. When remote control is disabled the agent must not advertise exec,
// terminal or file so that the panel can disable those features up front
// instead of letting the user click and be refused by the agent.
const (
	CapabilityPing     = "ping"
	CapabilityMessage  = "message"
	CapabilityEvent    = "event"
	CapabilityExec     = "exec"
	CapabilityTerminal = "terminal"
	CapabilityFile     = "file"
)

// PrivilegeLevel is a coarse-grained description of the OS account the agent
// runs as. It deliberately carries no account name, path or other identifying
// detail: the panel only needs to know whether the panel-equivalent privilege
// of this agent is elevated.
type PrivilegeLevel string

const (
	PrivilegeLevelElevated PrivilegeLevel = "elevated"
	PrivilegeLevelStandard PrivilegeLevel = "standard"
	PrivilegeLevelUnknown  PrivilegeLevel = "unknown"
)

// CapabilitiesMonitoringOnly lists the capabilities that stay available when
// remote control is disabled.
func CapabilitiesMonitoringOnly() []string {
	return []string{CapabilityPing, CapabilityMessage, CapabilityEvent}
}

// CapabilitiesRemoteControl lists the capabilities that remote control adds.
func CapabilitiesRemoteControl() []string {
	return []string{CapabilityExec, CapabilityTerminal, CapabilityFile}
}

// CapabilitiesAll lists the full capability set of an agent running with
// remote control enabled, in the order used on the wire.
func CapabilitiesAll() []string {
	caps := CapabilitiesMonitoringOnly()
	return append(caps, CapabilitiesRemoteControl()...)
}
