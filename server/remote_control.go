package server

import (
	"encoding/json"
	"log"
	"time"

	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

const remoteControlUnsupported = "method not supported: remote control is not compiled into this build"

// Capabilities returns the capability list advertised to the server.
func Capabilities() []string {
	return v2.CapabilitiesMonitoringOnly()
}

func isUnsupportedRemoteControlMethod(method string) bool {
	switch method {
	case v2.MethodAgentExec, v2.MethodAgentTerminal, v2.MethodAgentFile:
		return true
	default:
		return false
	}
}

func rejectExecTask(taskID string) {
	if taskID == "" {
		log.Printf("rejected legacy exec request: %s", remoteControlUnsupported)
		return
	}
	uploadTaskResult(taskID, remoteControlUnsupported, -1, time.Now())
}

func rejectFileOperation(operation v2.FileOperation) {
	result := v2.FileResult{
		UUID:      operation.UUID,
		RequestID: operation.RequestID,
		OK:        false,
		Error:     remoteControlUnsupported,
	}
	payload := v2.Request{
		JSONRPC: v2.Version,
		Method:  v2.MethodAgentFileResult,
		Params:  result,
	}
	if err := postV2RPC(payload); err != nil {
		log.Printf("failed to return legacy file rejection: %v", err)
	}
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

// reportPayload adds what this agent can do to a report payload.
//
// agent.report is parsed into a typed struct on the server side, so older
// servers simply ignore the extra fields. agent.basicInfo must NOT carry them:
// released servers map that payload straight onto SQL columns and reject
// unknown keys with "no such column", which would break basic info reporting.
func reportPayload(report []byte) []byte {
	augmented, err := addRemoteControlInfo(report)
	if err != nil {
		return report
	}
	return augmented
}

func addRemoteControlInfo(report []byte) ([]byte, error) {
	var decoded map[string]interface{}
	if err := json.Unmarshal(report, &decoded); err != nil {
		return nil, err
	}
	decoded["capabilities"] = Capabilities()
	decoded["privilege_level"] = string(PrivilegeLevel())
	return json.Marshal(decoded)
}
