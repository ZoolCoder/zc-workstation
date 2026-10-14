package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseValid(t *testing.T) {
	cfg, err := Parse([]byte(`
version: 1
targets:
  - name: notes
    provider: localdir
    path: out/notes
    prune: true
    files:
      README.md: "hello\n"
`))
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Names(); len(got) != 1 || got[0] != "notes" {
		t.Fatalf("names %v", got)
	}
	if tg, ok := cfg.Find("notes"); !ok || !tg.Prune || tg.Files["README.md"] != "hello\n" {
		t.Fatalf("target %+v", tg)
	}
}

func TestParseReportsEveryProblem(t *testing.T) {
	_, err := Parse([]byte(`
version: 2
targets:
  - name: Bad_Name
    provider: s3
    files:
      ../escape: x
  - name: ok
    provider: localdir
    path: a
  - name: ok
    provider: localdir
    path: b
`))
	if err == nil {
		t.Fatal("invalid config accepted")
	}
	for _, want := range []string{"version is 2", "kebab-case", `provider "s3"`, "path is required", "inside the target path", "declared twice"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
}

func TestParseRefusesUnknownKeys(t *testing.T) {
	if _, err := Parse([]byte("version: 1\ntragets: []\n")); err == nil {
		t.Fatal("unknown key accepted")
	}
}

func TestLoadResolvesPathsAgainstTheFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "tool.yaml")
	if err := os.WriteFile(path, []byte("version: 1\ntargets:\n  - {name: a, provider: localdir, path: out}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Root(cfg.Targets[0]); got != filepath.Join(dir, "out") {
		t.Fatalf("root %q", got)
	}
	cfg, err = Load("-", strings.NewReader("version: 1\n"))
	if err != nil || cfg.Dir != "" {
		t.Fatalf("stdin: %+v %v", cfg, err)
	}
}
