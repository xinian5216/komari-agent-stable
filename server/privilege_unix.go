//go:build !windows

package server

import (
	"os"

	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

// privilegeLevel reports whether the agent process runs as the root account.
// Non-root accounts are reported as standard; the effective uid is the only
// signal used because it is what an attacker with panel access would inherit.
func privilegeLevel() v2.PrivilegeLevel {
	if os.Geteuid() == 0 {
		return v2.PrivilegeLevelElevated
	}
	return v2.PrivilegeLevelStandard
}
