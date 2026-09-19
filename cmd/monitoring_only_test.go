package cmd

import "testing"

func TestLegacyRemoteControlFlagsAreHiddenCompatibilityNoOps(t *testing.T) {
	for _, name := range []string{"disable-web-ssh", "disable-remote-control"} {
		flag := RootCmd.PersistentFlags().Lookup(name)
		if flag == nil {
			t.Fatalf("legacy flag --%s was removed; old service definitions would fail to start", name)
		}
		if !flag.Hidden {
			t.Fatalf("legacy no-op --%s must stay hidden", name)
		}
	}
}
