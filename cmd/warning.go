package cmd

import (
	"fmt"
	"log"
	"net/url"
	"os"
	"os/user"
	"strconv"
	"strings"
	"unicode"

	"github.com/komari-monitor/komari-agent/server"
	"github.com/komari-monitor/komari-agent/utils"
)

const (
	warningTitle        = "[Komari] Remote control is enabled on this device"
	warningAdvice       = "If you did not set this up, your device may have been accessed without authorization."
	warningCompromise   = "Stop Komari Agent immediately and check your device for signs of compromise."
	warningUninstallURL = "https://komari-document.pages.dev/en/faq/uninstall"
	warningElevatedNote = "This agent runs with elevated privileges (root/Administrator/SYSTEM), so the panel can execute commands and access files with that privilege."
)

type securityWarning struct {
	PanelHost string
	RunAsUser string
	Elevated  bool
}

func newSecurityWarning(endpoint, runAsUser string) securityWarning {
	return securityWarning{
		PanelHost: warningHost(endpoint),
		RunAsUser: warningSingleLine(runAsUser),
		Elevated:  server.RunsElevated(),
	}
}

func (w securityWarning) message() string {
	privilege := ""
	if w.Elevated {
		privilege = "\n\n" + warningElevatedNote
	}
	return fmt.Sprintf("%s can execute commands and read or modify files on this device as %s.%s\n\n%s\n%s\n\nUninstall Komari Agent: %s",
		w.PanelHost, w.RunAsUser, privilege, warningAdvice, warningCompromise, warningUninstallURL)
}

// logRemoteControlStatus prints the effective remote control mode of this
// agent once at startup. The account name itself is only printed on the device,
// never reported to the panel.
func logRemoteControlStatus() {
	if flags.DisableWebSsh {
		log.Println("Remote control: disabled (monitoring only)")
		return
	}
	if server.RunsElevated() {
		log.Println("Remote control: enabled (elevated): this agent can execute commands and access files as root/Administrator/SYSTEM")
		return
	}
	log.Println("Remote control: enabled")
}

func warningHost(endpoint string) string {
	const unknownHost = "the configured Komari server"
	endpoint = strings.TrimSpace(endpoint)
	if !strings.Contains(endpoint, "://") && !strings.HasPrefix(endpoint, "//") {
		endpoint = "//" + endpoint
	}
	endpoint, err := utils.ConvertIDNToASCII(endpoint)
	if err != nil {
		return unknownHost
	}
	u, err := url.Parse(endpoint)
	if err != nil || u.Hostname() == "" {
		return unknownHost
	}
	host := warningSingleLine(u.Host)
	if host == "" {
		return unknownHost
	}
	return host
}

func warningSingleLine(value string) string {
	return strings.TrimSpace(strings.Map(func(r rune) rune {
		if !unicode.IsPrint(r) {
			return -1
		}
		return r
	}, value))
}

func warningCurrentUser() string {
	if uid := os.Geteuid(); uid >= 0 {
		if u, err := user.LookupId(strconv.Itoa(uid)); err == nil {
			return u.Username
		}
		return "UID " + strconv.Itoa(uid)
	}
	if u, err := user.Current(); err == nil {
		return u.Username
	}
	return "the agent's account"
}
