package engine

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
)

// stuck accepts every write and changes nothing, so verify must catch it.
type stuck struct{}

func (stuck) Plan(context.Context, config.Target) ([]plan.Action, error) {
	return []plan.Action{{Op: plan.OpCreate, Target: "t", Resource: "r",
		Do: func(context.Context) error { return nil }}}, nil
}
func (stuck) Status(context.Context, config.Target) (string, error) { return "stuck", nil }

func cfg(dir string) config.Config {
	return config.Config{Version: 1, Dir: dir, Targets: []config.Target{
		{Name: "a", Provider: "localdir", Path: "a", Files: map[string]string{"x": "1"}},
		{Name: "b", Provider: "localdir", Path: "b", Files: map[string]string{"y": "2"}},
	}}
}

func TestPlanApplyVerify(t *testing.T) {
	ctx := context.Background()
	e, err := New(cfg(t.TempDir()), Default(), []string{"b"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := e.Plan(ctx)
	if err != nil || len(p.Actions) != 1 || p.Actions[0].Target != "b" {
		t.Fatalf("plan %+v %v", p, err)
	}
	var out bytes.Buffer
	if err := e.Apply(ctx, p, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "applied and verified") {
		t.Fatalf("out %q", out.String())
	}
	if st := e.Status(ctx); len(st) != 1 || !strings.HasPrefix(st[0].Summary, "1 of 1") {
		t.Fatalf("status %+v", st)
	}
}

func TestApplyCatchesAWriteThatDidNothing(t *testing.T) {
	ctx := context.Background()
	c := cfg(t.TempDir())
	c.Targets[0].Provider = "stuck"
	e, _ := New(c, Providers{"stuck": stuck{}}, []string{"a"})
	p, _ := e.Plan(ctx)
	if err := e.Apply(ctx, p, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "still outstanding") {
		t.Fatalf("apply %v", err)
	}
}

func TestSelectAndMissingProvider(t *testing.T) {
	if _, err := New(cfg(""), Default(), []string{"nope"}); err == nil {
		t.Fatal("unknown target accepted")
	}
	e, _ := New(cfg(""), Providers{}, nil)
	if _, err := e.Plan(context.Background()); err == nil {
		t.Fatal("missing provider planned")
	}
	if st := e.Status(context.Background()); st[0].Error == "" {
		t.Fatalf("status %+v", st)
	}
}
