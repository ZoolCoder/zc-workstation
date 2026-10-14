package sh

import (
	"context"
	"strings"
	"testing"
)

func TestExecOutputCarriesStderr(t *testing.T) {
	if !(Exec{}).Has("go") {
		t.Skip("go is not on PATH")
	}
	out, err := Exec{}.Output(context.Background(), "go", "env", "GOOS")
	if err != nil || strings.TrimSpace(string(out)) == "" {
		t.Fatalf("%q %v", out, err)
	}
	_, err = Exec{}.Output(context.Background(), "go", "no-such-command")
	if err == nil || !strings.Contains(err.Error(), "go no-such-command") || !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("err %v", err)
	}
}

func TestFake(t *testing.T) {
	var seen string
	f := &Fake{Out: map[string]string{"a b": "out"}, Programs: []string{"a"}, OnRun: func(l string) { seen = l }}
	if out, err := f.Output(context.Background(), "a", "b"); err != nil || string(out) != "out" {
		t.Fatal(out, err)
	}
	if _, err := f.Output(context.Background(), "a", "c"); err == nil {
		t.Fatal("unknown command answered")
	}
	if err := f.Run(context.Background(), "x", "y"); err != nil || seen != "x y" || f.Ran[0] != "x y" {
		t.Fatal(err, seen, f.Ran)
	}
	if !f.Has("a") || f.Has("b") {
		t.Fatal("Has")
	}
}
