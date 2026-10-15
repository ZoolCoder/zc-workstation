package sh

import (
	"io"
	"os"
	"path/filepath"
)

// askpassScript asks for the password in a macOS dialog. sudo runs it in
// place of its terminal prompt; Touch ID still comes first when it is set up.
const askpassScript = `#!/bin/sh
exec /usr/bin/osascript \
  -e 'display dialog "zc-workstation needs your password to install or remove software." default answer "" with hidden answer with title "zc-workstation" with icon caution' \
  -e 'text returned of result'
`

// askpassEnv is the environment for a program that may run sudo. With no
// terminal to prompt on, as under an AI agent or launchd, it points
// SUDO_ASKPASS at the dialog; Homebrew then passes -A, and sudo uses the
// dialog on its own once DISPLAY is set. Otherwise it is nil: inherit as is.
func askpassEnv(stdin io.Reader) []string {
	if os.Getenv("SUDO_ASKPASS") != "" || isTerminal(stdin) {
		return nil
	}
	path, err := writeAskpass()
	if err != nil {
		return nil
	}
	env := append(os.Environ(), "SUDO_ASKPASS="+path)
	if os.Getenv("DISPLAY") == "" {
		env = append(env, "DISPLAY=:0")
	}
	return env
}

func isTerminal(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}

func writeAskpass() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "zc-workstation", "askpass")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	return path, os.WriteFile(path, []byte(askpassScript), 0o700)
}
