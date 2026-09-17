//go:build windows

package server

import (
	"os/user"
	"strings"

	"golang.org/x/sys/windows"

	v2 "github.com/komari-monitor/komari-agent/protocol/v2"
)

// privilegeLevel reports whether the agent process runs with an elevated
// Windows token (SYSTEM, a service account or a member of the built-in
// Administrators group). The account name is never reported.
//
// The check is intentionally conservative: it reports elevated for the
// well-known high-privilege accounts even when the token elevation flag is not
// set, and reports unknown when it cannot determine the level at all.
func privilegeLevel() v2.PrivilegeLevel {
	if processTokenIsElevated() || currentAccountIsHighPrivilege() {
		return v2.PrivilegeLevelElevated
	}
	if _, err := user.Current(); err != nil {
		return v2.PrivilegeLevelUnknown
	}
	return v2.PrivilegeLevelStandard
}

func processTokenIsElevated() bool {
	token := windows.GetCurrentProcessToken()
	if token.IsElevated() {
		return true
	}
	adminSid, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return false
	}
	isMember, err := token.IsMember(adminSid)
	if err != nil {
		return false
	}
	return isMember
}

// currentAccountIsHighPrivilege covers the service accounts that do not always
// carry the elevation flag: LocalSystem / NT AUTHORITY\SYSTEM and the built-in
// Administrator account.
func currentAccountIsHighPrivilege() bool {
	u, err := user.Current()
	if err != nil {
		return false
	}
	name := strings.ToLower(strings.TrimSpace(u.Username))
	if name == "system" || strings.HasSuffix(name, `\system`) {
		return true
	}
	sid := strings.TrimSpace(u.Uid)
	return isHighPrivilegeSID(sid)
}

// isHighPrivilegeSID matches the well-known high-privilege local SIDs:
// S-1-5-18 (LocalSystem) and the built-in Administrator (RID 500). Service
// accounts use the RID 18 domain SID.
func isHighPrivilegeSID(sid string) bool {
	if !strings.HasPrefix(sid, "S-1-") {
		return false
	}
	switch {
	case sid == "S-1-5-18":
		return true
	case strings.HasSuffix(sid, "-500"):
		return true
	}
	return false
}
