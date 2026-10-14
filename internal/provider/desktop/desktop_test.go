package desktop

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

const uuid = "CE085635-0000-0000-0000-000000000000"

type machine struct {
	p      Provider
	r      *sh.Fake
	t      config.Target
	prefs  string
	readSS string
}

// setup is a machine with the wallpaper and page on disk, the saver
// installed when saver is true, and nothing pointed at either yet.
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
	for _, f := range []string{tg.Wallpaper, tg.Screensaver} {
		if err := os.WriteFile(f, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if saver {
		if err := os.Mkdir(filepath.Join(home, "Library/Screen Savers", Saver), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	prefs := filepath.Join(home, "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/ByHost/WebViewScreenSaver."+uuid)
	readSS := sh.Line("defaults", "read", prefs, "kScreenSaverURLList")
	r := &sh.Fake{
		Out: map[string]string{
			sh.Line("osascript", "-e", pictures):                     "/System/Library/Desktop Pictures/Sky.heic\n" + tg.Wallpaper + "\n",
			sh.Line("ioreg", "-rd1", "-c", "IOPlatformExpertDevice"): `  "IOPlatformUUID" = "` + uuid + `"` + "\n",
		},
		Err: map[string]error{readSS: errors.New("Domain " + prefs + " not found.")},
	}
	return machine{Provider{r: r, home: home, system: filepath.Join(root, "system")}, r, tg, prefs, readSS}
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
		sh.Line("defaults", "write", m.prefs, "kScreenSaverURLList", "-array",
			"<dict><key>kScreenSaverURL</key><string>file://"+strings.ReplaceAll(m.t.Screensaver, " ", "%20")+"</string><key>kScreenSaverTime</key><integer>-1</integer></dict>"),
	}
	if strings.Join(m.r.Ran, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ran\n%s", strings.Join(m.r.Ran, "\n"))
	}
}

func TestInPlaceWhenEveryDesktopAndTheSaverMatch(t *testing.T) {
	m := setup(t, true)
	m.r.Out[sh.Line("osascript", "-e", pictures)] = m.t.Wallpaper + "\n" + m.t.Wallpaper + "\n"
	delete(m.r.Err, m.readSS)
	m.r.Out[m.readSS] = "(\n    {\n        kScreenSaverTime = \"-1\";\n        kScreenSaverURL = \"" + fileURL(m.t.Screensaver) + "\";\n    }\n)\n"
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
	if err := os.MkdirAll(filepath.Join(m.p.system, "Screen Savers", Saver), 0o755); err != nil {
		t.Fatal(err)
	}
	items, err := m.p.Items(context.Background(), m.t)
	if err != nil || len(items) != 2 || items[1].Kind != "screensaver" || items[1].State != "differs" {
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
