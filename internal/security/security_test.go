package security

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// secure answers every check as a hardened Mac does.
func secure() map[string]string {
	return map[string]string{
		"fdesetup status":                                "FileVault is On.\n",
		firewall + " --getglobalstate":                   "Firewall is enabled. (State = 1)\n",
		firewall + " --getstealthmode":                   "Firewall stealth mode is on\n",
		"/bin/sh -c sysadminctl -screenLock status 2>&1": "sysadminctl[1] screenLock delay is immediate\n",
		"spctl --status":                                 "assessments enabled\n",
		"csrutil status":                                 "System Integrity Protection status: enabled.\n",
		"softwareupdate --schedule":                      "Automatic checking for updates is turned on\n",
		"/bin/sh -c defaults read /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall; defaults read /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall": "1\n1\n",
		"netstat -an -p tcp":          "tcp4  0  0  127.0.0.1.5432  *.*  LISTEN\n",
		"lsof -nP -iTCP -sTCP:LISTEN": "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nrapportd 1 me 4u IPv4 0x1 0t0 TCP *:49152 (LISTEN)\npostgres 2 me 7u IPv4 0x2 0t0 TCP 127.0.0.1:5432 (LISTEN)\n",
	}
}

func checker(t *testing.T, out map[string]string, pam string) Checker {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sudo_local")
	if err := os.WriteFile(path, []byte(pam), 0o600); err != nil {
		t.Fatal(err)
	}
	return Checker{r: &sh.Fake{Out: out}, pam: path}
}

func TestHardenedMacPasses(t *testing.T) {
	for _, r := range checker(t, secure(), "auth       sufficient     pam_tid.so\n").Run(context.Background()) {
		if !r.OK {
			t.Errorf("%s: %s", r.Name, r.Detail)
		}
	}
}

func TestOpenMacFailsWithFixes(t *testing.T) {
	out := secure()
	// "disabled" contains "enabled"; the check must not read it as on.
	out[firewall+" --getglobalstate"] = "Firewall is disabled. (State = 0)\n"
	out["/bin/sh -c sysadminctl -screenLock status 2>&1"] = "sysadminctl[1] screenLock is off\n"
	out["netstat -an -p tcp"] = "tcp4  0  0  *.445  *.*  LISTEN\n"
	out["lsof -nP -iTCP -sTCP:LISTEN"] += "node 3 me 20u IPv6 0x3 0t0 TCP *:3000 (LISTEN)\n"
	delete(out, "csrutil status")
	got := map[string]Result{}
	for _, r := range checker(t, out, "#auth       sufficient     pam_tid.so\n").Run(context.Background()) {
		got[r.Name] = r
	}
	for _, name := range []string{"firewall", "password after sleep or screen saver", "File Sharing off", "System Integrity Protection", "Touch ID for sudo"} {
		if r := got[name]; r.OK || r.Warn || r.Detail == "" {
			t.Errorf("%s: %+v, want a failure with a fix", name, r)
		}
	}
	if r := got["servers on every network interface"]; !r.Warn || r.Detail != "node:3000; bind dev servers to 127.0.0.1" {
		t.Errorf("exposed: %+v", r)
	}
	if !got["FileVault disk encryption"].OK {
		t.Error("FileVault should still pass")
	}
}
