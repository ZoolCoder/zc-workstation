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
  - name: escape
    provider: localdir
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
	for _, want := range []string{"version is 2", "kebab-case", `provider "s3"`, "path is required for provider localdir", "inside the target path", "declared twice"} {
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

func TestParseChecksEachProvidersFields(t *testing.T) {
	_, err := Parse([]byte(`
version: 1
targets:
  - {name: pk, provider: packages, manager: pacman, os: [plan9]}
  - {name: df, provider: dotfiles, mode: hardlink, file: x, upgrade: true}
  - {name: tl, provider: tools, source: home, wallpaper: w.png}
  - {name: dk, provider: desktop, file: x}
  - {name: dl, provider: desktop, os: [darwin, linux], screensaver: s.html}
  - {name: da, provider: desktop, os: [darwin], accent: teal}
  - {name: st, provider: settings, os: [darwin]}
  - {name: sv, provider: settings, os: [darwin], defaults: {com.apple.dock: {persistent-apps: [a]}}, services: [x]}
  - {name: se, provider: services, os: [darwin], agents: [job.txt]}
  - {name: sl, provider: services, os: [darwin, linux], services: [x]}
  - {name: su, provider: services, os: [linux], agents: [a.plist]}
  - {name: gl, provider: settings, os: [linux], defaults: {a: {b: 1}}}
  - {name: gm, provider: settings, os: [darwin], defaults: {a: {b: 1}}, gsettings: {a: {b: 1}}}
  - {name: gv, provider: settings, os: [linux], gsettings: {org.gnome.x: {k: [1, 2]}}}
  - {name: go, provider: settings, os: [darwin, linux], defaults: {a: {b: 1}}}
  - {name: sm, provider: services, os: [darwin], agents: [a.timer]}
  - {name: kb, provider: keyboard, os: [darwin]}
`))
	if err == nil {
		t.Fatal("invalid config accepted")
	}
	for _, want := range []string{
		"target pk: file is required", `manager "pacman"`, `os "plan9"`,
		"target df: source is required", `mode "hardlink"`, "target df: file does nothing", "target df: upgrade does nothing",
		"target tl: file is required", "target tl: source does nothing", "target tl: wallpaper does nothing",
		"target dk: set wallpaper, screensaver or accent", "target dk: file does nothing", "target dk: provider desktop drives macOS only",
		"target dl: provider desktop drives macOS only", `target da: accent "teal" is not one of`,
		"target st: defaults is required", "target sv: com.apple.dock persistent-apps must be a bool, number or string",
		"target sv: services does nothing", `target se: agent "job.txt" must be a .plist, .service or .timer file`,
		"target sl: provider services drives one system", `target su: agent "a.plist" is a launchd plist`,
		`target sm: agent "a.timer" is a systemd unit`,
		"target gl: gsettings is required for provider settings on linux", "target gl: defaults does nothing",
		"target gm: gsettings does nothing", "target gv: org.gnome.x k must be a bool, number, string or list of strings",
		"target go: provider settings drives one system",
		"target kb: file is required", "target kb: provider keyboard drives keyd on Linux only",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error lacks %q:\n%v", want, err)
		}
	}
}

func TestResolveExpandsHomeAndRelativePaths(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip(err)
	}
	dir, abs := t.TempDir(), t.TempDir()
	c := Config{Dir: dir}
	got := c.Resolve(Target{File: "packages/Brewfile", Source: "~/dots", Destination: abs})
	if got.File != filepath.Join(dir, "packages/Brewfile") || got.Source != filepath.Join(home, "dots") || got.Destination != abs {
		t.Fatalf("resolved %+v", got)
	}
}

func TestForOS(t *testing.T) {
	if !(Target{}).ForOS("linux") || (Target{OS: []string{"darwin"}}).ForOS("linux") {
		t.Fatal("ForOS")
	}
}

func TestExampleConfigIsValid(t *testing.T) {
	if _, err := Load(filepath.Join("..", "..", "zc-workstation.example.yaml"), nil); err != nil {
		t.Fatal(err)
	}
}
