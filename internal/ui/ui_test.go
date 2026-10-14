package ui

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/zoolcoder/toolshell/activity"
	"github.com/zoolcoder/zc-workstation/internal/engine"
)

func newPage(t *testing.T) (*Server, string) {
	t.Helper()
	root := t.TempDir()
	cfg := filepath.Join(root, "tool.yaml")
	body := "version: 1\ntargets:\n  - {name: notes, provider: localdir, path: out, prune: true, files: {a.txt: A}}\n"
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := New(Deps{Name: "tool", ConfigPath: cfg, Providers: engine.Default(),
		Activity: &activity.Log{Path: filepath.Join(root, "activity.jsonl")},
		Now:      func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }})
	if err != nil {
		t.Fatal(err)
	}
	return s, filepath.Join(root, "out")
}

func do(s *Server, method, path string, form url.Values) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
	if method == http.MethodPost {
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}

func TestPagesRender(t *testing.T) {
	s, _ := newPage(t)
	for path, want := range map[string]string{
		"/": "notes", "/targets/notes": "press", "/activity": "nothing recorded yet", "/settings": "localdir",
	} {
		w := do(s, http.MethodGet, path, nil)
		if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), want) {
			t.Errorf("%s: %d, lacks %q", path, w.Code, want)
		}
	}
	if w := do(s, http.MethodGet, "/targets/missing", nil); w.Code != http.StatusNotFound {
		t.Errorf("missing target %d", w.Code)
	}
}

func TestPlanThenApplyBehindTypedName(t *testing.T) {
	s, dir := newPage(t)
	if w := do(s, http.MethodPost, "/targets/notes/apply", url.Values{"confirm": {"notes"}}); !strings.Contains(w.Header().Get("Location"), "err=plan+first") {
		t.Fatalf("apply before plan: %v", w.Header())
	}
	if w := do(s, http.MethodPost, "/targets/notes/plan", nil); w.Code != http.StatusSeeOther {
		t.Fatalf("plan %d", w.Code)
	}
	if w := do(s, http.MethodGet, "/targets/notes", nil); !strings.Contains(w.Body.String(), "CREATE") {
		t.Fatal("plan not shown")
	}
	if w := do(s, http.MethodPost, "/targets/notes/apply", url.Values{"confirm": {"wrong"}}); !strings.Contains(w.Header().Get("Location"), "err=") {
		t.Fatal("wrong name accepted")
	}
	w := do(s, http.MethodPost, "/targets/notes/apply", url.Values{"confirm": {"notes"}})
	if loc := w.Header().Get("Location"); !strings.Contains(loc, "msg=applied") {
		t.Fatalf("apply: %s", loc)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "A" {
		t.Fatalf("a.txt %q", b)
	}
	if w := do(s, http.MethodGet, "/activity", nil); !strings.Contains(w.Body.String(), "1 change(s) applied") {
		t.Fatal("apply not in activity")
	}
}

func TestApplyRefusesDeletesAndMovedState(t *testing.T) {
	s, dir := newPage(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	do(s, http.MethodPost, "/targets/notes/plan", nil)
	if w := do(s, http.MethodGet, "/targets/notes", nil); !strings.Contains(w.Body.String(), "tool apply -config") {
		t.Fatal("terminal command not shown for a deleting plan")
	}
	if loc := do(s, http.MethodPost, "/targets/notes/apply", url.Values{"confirm": {"notes"}}).Header().Get("Location"); !strings.Contains(loc, "terminal") {
		t.Fatalf("deleting plan applied: %s", loc)
	}
	_ = os.Remove(filepath.Join(dir, "stray.txt"))
	if loc := do(s, http.MethodPost, "/targets/notes/apply", url.Values{"confirm": {"notes"}}).Header().Get("Location"); !strings.Contains(loc, "changed+since") {
		t.Fatalf("moved state applied: %s", loc)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); err == nil {
		t.Fatal("wrote after refusing")
	}
}
