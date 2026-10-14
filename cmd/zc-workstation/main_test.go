package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixture writes a config with one pruned target and returns its path and the
// target directory.
func fixture(t *testing.T) (cfg, dir string) {
	t.Helper()
	root := t.TempDir()
	cfg = filepath.Join(root, name+".yaml")
	body := "version: 1\ntargets:\n  - name: notes\n    provider: localdir\n    path: out\n    prune: true\n    files:\n      a.txt: \"A\\n\"\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return cfg, filepath.Join(root, "out")
}

func run(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out, errOut bytes.Buffer
	err := runCLI(args, strings.NewReader(stdin), &out, &errOut)
	return out.String() + errOut.String(), err
}

func TestPlanApplyConverge(t *testing.T) {
	cfg, dir := fixture(t)
	out, err := run(t, "", "plan", "-config", cfg, "-exit-code")
	if !errors.Is(err, errDrift) || !strings.Contains(out, "CREATE  notes  a.txt") {
		t.Fatalf("plan: %v\n%s", err, out)
	}
	if out, err = run(t, "", "apply", "-config", cfg); err != nil || !strings.Contains(out, "applied and verified") {
		t.Fatalf("apply: %v\n%s", err, out)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "A\n" {
		t.Fatalf("a.txt %q", b)
	}
	if _, err := run(t, "", "plan", "-config", cfg, "-exit-code"); err != nil {
		t.Fatalf("converged plan: %v", err)
	}
	if out, _ := run(t, "", "status", "-config", cfg); !strings.Contains(out, "1 of 1 declared files") {
		t.Fatalf("status %s", out)
	}
}

func TestSavedPlanRefusesWhenTheWorldMoved(t *testing.T) {
	cfg, dir := fixture(t)
	saved := filepath.Join(t.TempDir(), "plan.json")
	if _, err := run(t, "", "plan", "-config", cfg, "-json", "-out", saved); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(saved); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("saved plan %v %v", info, err)
	}
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("other"), 0o600)
	if _, err := run(t, "", "apply", "-config", cfg, saved); err == nil || !strings.Contains(err.Error(), "changed since") {
		t.Fatalf("moved world applied: %v", err)
	}
	if _, err := run(t, "", "apply", "-config", cfg, "-target", "other", saved); err == nil {
		t.Fatal("different selection accepted")
	}
}

func TestDeletionsNeedAYes(t *testing.T) {
	cfg, dir := fixture(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "a.txt"), []byte("A\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)

	if _, err := run(t, "", "apply", "-config", cfg); !errors.Is(err, errCancelled) {
		t.Fatalf("no answer: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err != nil {
		t.Fatal("deleted without a yes")
	}
	if _, err := run(t, "yes\n", "apply", "-config", cfg); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err == nil {
		t.Fatal("stray.txt survived a yes")
	}
}

func TestValidateDoctorVersionAndErrors(t *testing.T) {
	cfg, _ := fixture(t)
	if out, err := run(t, "", "validate", "-config", cfg); err != nil || !strings.Contains(out, "1 target(s), valid") {
		t.Fatalf("validate: %v %s", err, out)
	}
	out, err := run(t, "", "doctor", "-config", cfg, "-json")
	var report struct {
		Checks []struct{ Name, Status string }
	}
	if jerr := json.Unmarshal([]byte(out[:strings.LastIndex(out, "}")+1]), &report); jerr != nil || len(report.Checks) != 3 {
		t.Fatalf("doctor: %v %v\n%s", err, jerr, out)
	}
	if out, _ := run(t, "", "version"); out != "dev\n" {
		t.Fatalf("version %q", out)
	}
	if _, err := run(t, "", "nope"); err == nil {
		t.Fatal("unknown command accepted")
	}
	if _, err := run(t, "version: 1\ntargets: [{name: x, provider: localdir, path: out, prune: true}]\n", "apply", "-config", "-"); err != nil {
		t.Fatalf("empty stdin plan: %v", err)
	}
	out, _ = run(t, "", "help")
	for cmd := range optional {
		if !strings.Contains(out, name+" "+cmd) {
			t.Fatalf("usage lacks %s:\n%s", cmd, out)
		}
	}
}
