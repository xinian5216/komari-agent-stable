package v2

// Capability names advertised by the monitoring-only agent to the server.
const (
	CapabilityPing    = "ping"
	CapabilityMessage = "message"
	CapabilityEvent   = "event"
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

// CapabilitiesMonitoringOnly is the complete capability set compiled into this
// fork. Remote command, terminal and file capabilities intentionally do not
// exist here, so they cannot accidentally be advertised again.
func CapabilitiesMonitoringOnly() []string {
	return []string{CapabilityPing, CapabilityMessage, CapabilityEvent}
}
