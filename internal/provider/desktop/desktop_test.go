package desktop

import (
	"context"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

type machine struct {
	p      Provider
	r      *sh.Fake
	t      config.Target
	saver  string
	readSS string
}

// setup is a machine with the wallpaper, and a page loading a font, on disk;
// the saver installed when saver is true; and nothing pointed at either yet.
func setup(t *testing.T, saver bool) machine {
	t.Helper()
	root := t.TempDir()
	home, art := filepath.Join(root, "home"), filepath.Join(root, "art dir")
	for _, dir := range []string{art, filepath.Join(home, "Library/Screen Savers")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	tg := config.Target{Name: "look", Provider: "desktop", OS: []string{"darwin"},
		Wallpaper: filepath.Join(art, "wall.png"), Screensaver: filepath.Join(art, "index.html")}
	files := map[string]string{tg.Wallpaper: "", tg.Screensaver: "<style>@font-face{src:url(fonts/a.woff2)}</style>",
		filepath.Join(art, "fonts/a.woff2"): "FONT"}
	for f, body := range files {
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	saverDir := filepath.Join(home, "Library/Screen Savers", Saver)
	if saver {
		if err := os.MkdirAll(filepath.Join(saverDir, "Contents"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	readSS := sh.Line("plutil", "-extract", defaultURLKey, "raw", "-o", "-", filepath.Join(saverDir, "Contents/Info.plist"))
	r := &sh.Fake{Out: map[string]string{
		sh.Line("osascript", "-e", pictures): "/System/Library/Desktop Pictures/Sky.heic\n" + tg.Wallpaper + "\n",
		readSS:                               "http://www.google.com/\n",
	}}
	return machine{Provider{r: r, home: home, system: filepath.Join(root, "system")}, r, tg, saverDir, readSS}
}

// page is what the saver should hold for setup's page: the page as a data URL,
// its font inlined.
func page() string {
	html := "<style>@font-face{src:url(data:font/woff2;base64," + base64.StdEncoding.EncodeToString([]byte("FONT")) + ")}</style>"
	return "data:text/html;base64," + base64.StdEncoding.EncodeToString([]byte(html))
}

func TestPlanSetsWallpaperAndPointsTheSaver(t *testing.T) {
	m := setup(t, true)
	ctx := context.Background()
	actions, err := m.p.Plan(ctx, m.t)
	if err != nil || len(actions) != 2 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	for _, a := range actions {
		if a.Op != plan.OpUpdate {
			t.Fatalf("%s is %s", a.Resource, a.Op)
		}
		if err := a.Do(ctx); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		sh.Line("osascript", "-e", "on run argv", "-e", `tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)`, "-e", "end run", m.t.Wallpaper),
		sh.Line("plutil", "-replace", defaultURLKey, "-string", page(), filepath.Join(m.saver, "Contents/Info.plist")),
		sh.Line("codesign", "--force", "--sign", "-", m.saver),
	}
	if strings.Join(m.r.Ran, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran\n%s", strings.Join(m.r.Ran, "\n"))
	}
}

func TestInPlaceWhenEveryDesktopAndTheSaverMatch(t *testing.T) {
	m := setup(t, true)
	m.r.Out[sh.Line("osascript", "-e", pictures)] = m.t.Wallpaper + "\n" + m.t.Wallpaper + "\n"
	m.r.Out[m.readSS] = page() + "\n"
	ctx := context.Background()
	if actions, err := m.p.Plan(ctx, m.t); err != nil || len(actions) != 0 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	live, err := m.p.Measure(ctx, m.t)
	if err != nil || live.InPlace != 2 || live.Declared != 2 || live.Summary != "wallpaper in place, screensaver in place" {
		t.Fatalf("live %+v %v", live, err)
	}
}

func TestMissingSaverOrFilesAreManual(t *testing.T) {
	m := setup(t, false)
	_ = os.Remove(m.t.Wallpaper)
	actions, err := m.p.Plan(context.Background(), m.t)
	if err != nil || len(actions) != 2 {
		t.Fatalf("plan %+v %v", actions, err)
	}
	if a := actions[0]; a.Op != plan.OpManual || a.Resource != "wallpaper" || !strings.Contains(a.Detail, "no picture at") {
		t.Fatalf("wallpaper %+v", a)
	}
	if a := actions[1]; a.Op != plan.OpManual || a.Resource != "webviewscreensaver" || !strings.Contains(a.Detail, "build-saver.sh") {
		t.Fatalf("saver %+v", a)
	}
}

func TestSystemWideSaverCounts(t *testing.T) {
	m := setup(t, false)
	saver := filepath.Join(m.p.system, "Screen Savers", Saver)
	if err := os.MkdirAll(saver, 0o755); err != nil {
		t.Fatal(err)
	}
	m.r.Out[sh.Line("plutil", "-extract", defaultURLKey, "raw", "-o", "-", filepath.Join(saver, "Contents/Info.plist"))] = page()
	items, err := m.p.Items(context.Background(), m.t)
	if err != nil || len(items) != 2 || items[1].Kind != "screensaver" || items[1].State != "in place" {
		t.Fatalf("items %+v %v", items, err)
	}
}

func TestOnlyTheKeysSetAreRead(t *testing.T) {
	m := setup(t, true)
	m.t.Screensaver = ""
	items, err := m.p.Items(context.Background(), m.t)
	if err != nil || len(items) != 1 || items[0].Kind != "wallpaper" {
		t.Fatalf("items %+v %v", items, err)
	}
	if progs := m.p.Programs(m.t); strings.Join(progs, " ") != "osascript" {
		t.Fatalf("programs %v", progs)
	}
}
