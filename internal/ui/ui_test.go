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
	"github.com/zoolcoder/zc-workstation/internal/sh"
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
		"/inventory": `data-search="notes file a.txt missing`,
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

func TestThemeLoadsOnEveryPage(t *testing.T) {
	s, _ := newPage(t)
	for _, path := range []string{"/", "/inventory", "/targets/notes", "/activity", "/settings", "/targets/missing", "/nope"} {
		if w := do(s, http.MethodGet, path, nil); !strings.Contains(w.Body.String(), `href="/zc/theme.css"`) {
			t.Errorf("%s: no theme stylesheet", path)
		}
	}
	for _, path := range []string{"/", "/nope"} {
		if w := do(s, http.MethodGet, path, nil); !strings.Contains(w.Body.String(), `<svg class="zc-orbit"`) {
			t.Errorf("%s: no orbit art", path)
		}
	}
	for _, path := range []string{"/zc/theme.css", "/zc/fonts/unbounded-latin-wght-normal.woff2"} {
		if w := do(s, http.MethodGet, path, nil); w.Code != http.StatusOK {
			t.Errorf("%s: %d", path, w.Code)
		}
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

func TestDashboardCountsAndSkips(t *testing.T) {
	defer func(goos string) { engine.GOOS = goos }(engine.GOOS)
	engine.GOOS = "linux"
	root := t.TempDir()
	cfg := filepath.Join(root, "tool.yaml")
	body := `version: 1
targets:
  - {name: notes, provider: localdir, path: out, files: {a.txt: A, b.txt: B}}
  - {name: winget, provider: packages, os: [windows], file: winget.json}
  - {name: runtimes, provider: tools, file: mise.toml}
`
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "out"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "out", "a.txt"), []byte("A"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := New(Deps{Name: "tool", ConfigPath: cfg, Providers: engine.With(&sh.Fake{}),
		Has: func(string) bool { return false }})
	if err != nil {
		t.Fatal(err)
	}
	w := do(s, http.MethodGet, "/", nil)
	page := w.Body.String()
	for _, want := range []string{
		"This machine", "1 target(s) cannot be read", "mise is not on PATH",
		`<span class="chip zero">skipped</span>`, "1 <small>of 2</small>", "<code>mise</code>",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("dashboard lacks %q", want)
		}
	}
	if w.Code != http.StatusOK {
		t.Fatalf("status %d", w.Code)
	}
}

func TestInventoryGroupsItems(t *testing.T) {
	var p inventoryPage
	p.fill([]engine.TargetItems{
		{Target: "brew", Items: []engine.Item{
			{Name: "git", Kind: "brew", State: engine.InPlace},
			{Name: "ghostty", Kind: "cask", State: engine.Missing},
			{Name: "x/tap", Kind: "tap", State: engine.InPlace},
		}},
		{Target: "dots", Items: []engine.Item{
			{Name: ".zshrc", Kind: "dotfile", State: engine.InPlace, App: "zsh"},
			{Name: ".zprofile", Kind: "dotfile", State: engine.Differs, App: "zsh"},
			{Name: ".gitconfig", Kind: "dotfile", State: engine.InPlace, App: "git"},
		}},
		{Target: "more", Items: []engine.Item{
			{Name: "tmux", Kind: "brew", State: engine.Outdated, Latest: "3.8"},
			{Name: "jq", Kind: "brew", State: engine.Extra},
		}},
		{Target: "apt", Skipped: true},
	})
	if p.Tools != (group{2, 2}) || p.Desktop != (group{0, 1}) || p.Dotfiles != (group{2, 3}) || p.Behind != 2 || p.Outdated != 1 || p.Extra != 1 {
		t.Fatalf("groups %+v %+v %+v behind %d", p.Tools, p.Desktop, p.Dotfiles, p.Behind)
	}
	if len(p.Apps) != 2 || p.Apps[0] != (configured{"git", 1, 0}) || p.Apps[1] != (configured{"zsh", 2, 1}) {
		t.Fatalf("apps %+v", p.Apps)
	}
	if len(p.Unread) != 1 || len(p.Rows) != 8 {
		t.Fatalf("unread %d rows %d", len(p.Unread), len(p.Rows))
	}
}
