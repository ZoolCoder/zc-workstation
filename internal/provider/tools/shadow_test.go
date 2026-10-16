package tools

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/sh"
)

func TestShadowedFindsCommandsRunFromElsewhere(t *testing.T) {
	exe := ""
	if runtime.GOOS == "windows" {
		exe = ".exe"
	}
	root := t.TempDir()
	node, java21, java25 := filepath.Join(root, "node", "bin"), filepath.Join(root, "java21", "bin"), filepath.Join(root, "java25", "bin")
	for path, mode := range map[string]os.FileMode{
		filepath.Join(node, "node"+exe): 0o755, filepath.Join(node, "npm"+exe): 0o755, filepath.Join(node, "README"): 0o644,
		filepath.Join(java25, "java"+exe): 0o755, filepath.Join(java21, "java"+exe): 0o755, filepath.Join(java21, "jar"+exe): 0o755,
	} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, nil, mode); err != nil {
			t.Fatal(err)
		}
	}
	r := &sh.Fake{Out: map[string]string{"mise bin-paths -C dir": node + "\n" + java25 + "\n" + java21 + "\n"}}
	onPath := map[string]string{
		"node" + exe: "/opt/homebrew/bin/node",
		"npm" + exe:  filepath.Join(root, "mise", "shims", "npm"+exe),
		"java" + exe: filepath.Join(java25, "java"+exe),
	}
	lookPath := func(name string) (string, error) {
		if p, ok := onPath[name]; ok {
			return p, nil
		}
		return "", errors.New("not found")
	}
	got, err := Shadowed(context.Background(), r, "dir", lookPath)
	if err != nil {
		t.Fatal(err)
	}
	want := []Shadow{
		{Name: "node" + exe, Want: filepath.Join(node, "node"+exe), Got: "/opt/homebrew/bin/node"},
		{Name: "jar" + exe, Want: filepath.Join(java21, "jar"+exe)},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("shadowed\n got %+v\nwant %+v", got, want)
	}
}

func TestRunnableExtFollowsPathext(t *testing.T) {
	for _, c := range []struct {
		ext, pathext string
		want         bool
	}{
		{".exe", "", true},
		{".EXE", ".COM;.EXE;.BAT", true},
		{".ps1", ".COM;.EXE", false},
		{"", ".COM;.EXE", false},
	} {
		if got := runnableExt(c.ext, c.pathext); got != c.want {
			t.Errorf("runnableExt(%q, %q) = %v, want %v", c.ext, c.pathext, got, c.want)
		}
	}
}
