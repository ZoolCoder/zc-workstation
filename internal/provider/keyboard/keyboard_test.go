package keyboard

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

const show = "systemctl show keyd --property=ActiveState,UnitFileState"

func setup(t *testing.T, have string) (config.Target, string) {
	dir := t.TempDir()
	src, conf := filepath.Join(dir, "default.conf"), filepath.Join(dir, "etc", "default.conf")
	if err := os.WriteFile(src, []byte("[main]\ncapslock = overload(hyper, esc)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if have != "" {
		if err := os.MkdirAll(filepath.Dir(conf), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(conf, []byte(have), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return config.Target{Name: "keys", Provider: "keyboard", OS: []string{"linux"}, File: src}, conf
}

func ops(t *testing.T, actions []plan.Action) []string {
	var got []string
	for _, a := range actions {
		got = append(got, string(a.Op)+" "+a.Resource)
		if a.Do != nil {
			if err := a.Do(context.Background()); err != nil {
				t.Fatal(err)
			}
		}
	}
	return got
}

func TestPlanInstallsConfigAndEnablesKeyd(t *testing.T) {
	tg, conf := setup(t, "")
	r := &sh.Fake{Programs: []string{"keyd"}, Out: map[string]string{show: "ActiveState=inactive\nUnitFileState=disabled\n"}}
	actions, err := Provider{r: r, conf: conf}.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"CREATE keyd:" + conf, "CREATE service:keyd"}
	if got := ops(t, actions); !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{"sudo install -D -m 644 " + tg.File + " " + conf, "sudo systemctl enable --now keyd"}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
}

func TestPlanReloadsARunningKeyd(t *testing.T) {
	tg, conf := setup(t, "[main]\n")
	r := &sh.Fake{Programs: []string{"keyd.rvaiya"}, Out: map[string]string{show: "ActiveState=active\nUnitFileState=enabled\n"}}
	p := Provider{r: r, conf: conf}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	if got := ops(t, actions); !slices.Equal(got, []string{"UPDATE keyd:" + conf}) {
		t.Fatalf("plan %q", got)
	}
	if !slices.Equal(r.Ran, []string{"sudo install -D -m 644 " + tg.File + " " + conf, "sudo keyd.rvaiya reload"}) {
		t.Fatalf("ran %q", r.Ran)
	}
	live, _ := p.Measure(context.Background(), tg)
	if live.InPlace != 1 || live.Declared != 2 {
		t.Fatalf("live %+v", live)
	}
}

func TestPlanAsksForKeydFirst(t *testing.T) {
	tg, conf := setup(t, "")
	actions, err := Provider{r: &sh.Fake{}, conf: conf}.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	if len(actions) != 1 || actions[0].Op != plan.OpManual || actions[0].Do != nil {
		t.Fatalf("plan %+v", actions)
	}
}
