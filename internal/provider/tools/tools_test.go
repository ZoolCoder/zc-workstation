package tools

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

func setup(t *testing.T) (config.Target, string) {
	dir := t.TempDir()
	file := filepath.Join(dir, "mise.toml")
	if err := os.WriteFile(file, []byte("[tools]\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Target{Name: "rt", Provider: "tools", File: file}, "mise ls --json -C " + dir
}

func TestPlanInstallsMissingVersionsFromThisFileOnly(t *testing.T) {
	tg, ls := setup(t)
	other := filepath.Join(t.TempDir(), "config.toml")
	if err := os.WriteFile(other, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	r := &sh.Fake{Programs: []string{"mise"}, Out: map[string]string{ls: `{
		"node": [{"version": "22.11.0", "requested_version": "lts", "installed": true, "source": {"path": "` + tg.File + `"}}],
		"java": [
			{"version": "temurin-25.0.1", "requested_version": "temurin-25", "installed": false, "source": {"path": "` + tg.File + `"}},
			{"version": "temurin-21.0.5", "requested_version": "temurin-21", "installed": true, "source": {"path": "` + tg.File + `"}}
		],
		"go": [{"version": "1.26.0", "requested_version": "latest", "installed": false, "source": {"path": "` + other + `"}}],
		"jq": [{"version": "1.7.1", "installed": true}]
	}`}}
	p := New(r)
	actions, err := p.Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Resource != "java@temurin-25" {
		t.Fatalf("plan %+v %v", actions, err)
	}
	_ = actions[0].Do(context.Background())
	if want := "mise install -C " + filepath.Dir(tg.File) + " java@temurin-25"; r.Ran[0] != want {
		t.Fatalf("ran %v", r.Ran)
	}
	live, err := p.Measure(context.Background(), tg)
	if err != nil || live.InPlace != 2 || live.Declared != 3 {
		t.Fatalf("live %+v %v", live, err)
	}
	items, err := p.Items(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, i.Name+" "+i.Version+" "+i.State+" ("+i.Desc+")")
	}
	want := "java temurin-21.0.5 in place (requested temurin-21)\njava temurin-25.0.1 missing (requested temurin-25)\nnode 22.11.0 in place (requested lts)"
	if strings.Join(got, "\n") != want {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestUntrustedConfigIsManual(t *testing.T) {
	tg, ls := setup(t)
	r := &sh.Fake{Programs: []string{"mise"}, Err: map[string]error{ls: errors.New("mise ERROR Config files in ~/x are not trusted.")}}
	actions, err := New(r).Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || !strings.Contains(actions[0].Detail, "mise trust") {
		t.Fatalf("plan %+v %v", actions, err)
	}
}

func TestMissingMiseIsManual(t *testing.T) {
	tg, _ := setup(t)
	actions, err := New(&sh.Fake{}).Plan(context.Background(), tg)
	if err != nil || len(actions) != 1 || actions[0].Resource != "mise" {
		t.Fatalf("plan %+v %v", actions, err)
	}
}
