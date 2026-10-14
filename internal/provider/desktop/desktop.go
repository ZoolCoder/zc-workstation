// Package desktop sets the macOS desktop picture and points the
// WebViewScreenSaver screen saver at a web page. System Events sets the
// picture; the saver's own preferences, written with defaults, hold the page.
package desktop

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// Saver is the screen saver bundle the screensaver key needs, installed by
// the webviewscreensaver Homebrew cask.
const Saver = "WebViewScreenSaver.saver"

type Provider struct {
	r sh.Runner
	// home holds Library; Saver may also sit in system, the shared Library.
	home, system string
}

func New(r sh.Runner) Provider {
	home, _ := os.UserHomeDir()
	return Provider{r: r, home: home, system: "/Library"}
}

// look is what the machine shows now, for each key the target sets.
type look struct {
	wallpaper, screensaver state
	// prefs is the saver's preference file, without .plist, as defaults
	// takes it.
	prefs string
}

// state is one key's reading: its item state and what to say about it.
type state struct {
	set    bool
	state  string
	detail string
	// resource names what a missing state's MANUAL step is about, when that
	// is not the key itself.
	resource string
}

func (p Provider) read(ctx context.Context, t config.Target) (look, error) {
	var l look
	if t.Wallpaper != "" {
		s, err := p.readWallpaper(ctx, t.Wallpaper)
		if err != nil {
			return l, err
		}
		l.wallpaper = s
	}
	if t.Screensaver != "" {
		s, prefs, err := p.readScreensaver(ctx, t.Screensaver)
		if err != nil {
			return l, err
		}
		l.screensaver, l.prefs = s, prefs
	}
	return l, nil
}

// pictures lists every desktop's picture, one path per line.
const pictures = `set AppleScript's text item delimiters to linefeed
tell application "System Events" to set p to picture of every desktop
return p as text`

func (p Provider) readWallpaper(ctx context.Context, want string) (state, error) {
	if _, err := os.Stat(want); err != nil {
		return state{set: true, state: provider.Missing, detail: "no picture at " + want + "; render it first"}, nil
	}
	out, err := p.r.Output(ctx, "osascript", "-e", pictures)
	if err != nil {
		return state{}, fmt.Errorf("read desktop pictures: %w", err)
	}
	for line := range strings.Lines(string(out)) {
		if line = strings.TrimSpace(line); line != "" && filepath.Clean(line) != want {
			return state{set: true, state: provider.Differs, detail: "a desktop shows " + filepath.Base(line)}, nil
		}
	}
	return state{set: true, state: provider.InPlace, detail: "on every desktop"}, nil
}

var (
	platformUUID = regexp.MustCompile(`"IOPlatformUUID" = "([0-9A-F-]+)"`)
	savedURL     = regexp.MustCompile(`kScreenSaverURL = "?([^";]+)"?;`)
)

func (p Provider) readScreensaver(ctx context.Context, page string) (state, string, error) {
	if _, err := os.Stat(page); err != nil {
		return state{set: true, state: provider.Missing, detail: "no page at " + page}, "", nil
	}
	if !p.saverInstalled() {
		return state{set: true, state: provider.Missing, resource: "webviewscreensaver",
			detail: `install the saver: add cask "webviewscreensaver" to your Brewfile, or brew install --cask webviewscreensaver`}, "", nil
	}
	out, err := p.r.Output(ctx, "ioreg", "-rd1", "-c", "IOPlatformExpertDevice")
	if err != nil {
		return state{}, "", fmt.Errorf("read hardware UUID: %w", err)
	}
	m := platformUUID.FindSubmatch(out)
	if m == nil {
		return state{}, "", fmt.Errorf("read hardware UUID: no IOPlatformUUID in ioreg output")
	}
	// The saver runs inside the legacy screen saver host, whose container
	// holds its per-host preferences.
	prefs := filepath.Join(p.home, "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Preferences/ByHost",
		"WebViewScreenSaver."+string(m[1]))
	out, err = p.r.Output(ctx, "defaults", "read", prefs, "kScreenSaverURLList")
	if err != nil {
		if strings.Contains(err.Error(), "not found") || strings.Contains(err.Error(), "does not exist") {
			return state{set: true, state: provider.Differs, detail: "WebViewScreenSaver shows no page yet"}, prefs, nil
		}
		return state{}, "", fmt.Errorf("read WebViewScreenSaver settings: %w", err)
	}
	urls := savedURL.FindAllSubmatch(out, -1)
	if len(urls) == 1 && string(urls[0][1]) == fileURL(page) {
		return state{set: true, state: provider.InPlace, detail: "WebViewScreenSaver shows it"}, prefs, nil
	}
	return state{set: true, state: provider.Differs, detail: "WebViewScreenSaver shows another page"}, prefs, nil
}

func (p Provider) saverInstalled() bool {
	for _, lib := range []string{filepath.Join(p.home, "Library"), p.system} {
		if _, err := os.Stat(filepath.Join(lib, "Screen Savers", Saver)); err == nil {
			return true
		}
	}
	return false
}

func fileURL(path string) string { return (&url.URL{Scheme: "file", Path: path}).String() }

// Plan sets what differs. A missing file or saver is MANUAL: rendering art and
// installing software are steps a person takes.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	l, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	switch l.wallpaper.state {
	case provider.Missing:
		actions = append(actions, manual(t, "wallpaper", l.wallpaper))
	case provider.Differs:
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "wallpaper",
			Detail: "set " + filepath.Base(t.Wallpaper) + " on every desktop",
			Do: func(ctx context.Context) error {
				return p.r.Run(ctx, "osascript", "-e", "on run argv",
					"-e", `tell application "System Events" to set picture of every desktop to POSIX file (item 1 of argv)`,
					"-e", "end run", t.Wallpaper)
			}})
	}
	switch l.screensaver.state {
	case provider.Missing:
		actions = append(actions, manual(t, "screensaver", l.screensaver))
	case provider.Differs:
		entry := "<dict><key>kScreenSaverURL</key><string>" + fileURL(t.Screensaver) + "</string>" +
			"<key>kScreenSaverTime</key><integer>-1</integer></dict>"
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "screensaver",
			Detail: "show " + filepath.Base(t.Screensaver) + " in WebViewScreenSaver; pick it once in System Settings, Screen Saver",
			Do: func(ctx context.Context) error {
				return p.r.Run(ctx, "defaults", "write", l.prefs, "kScreenSaverURLList", "-array", entry)
			}})
	}
	return actions, nil
}

func manual(t config.Target, key string, s state) plan.Action {
	if s.resource != "" {
		key = s.resource
	}
	return plan.Action{Op: plan.OpManual, Target: t.Name, Resource: key, Detail: s.detail}
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	items, err := p.Items(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(items)}
	var parts []string
	for _, i := range items {
		if i.State == provider.InPlace {
			live.InPlace++
		}
		parts = append(parts, i.Kind+" "+i.State)
	}
	live.Summary = strings.Join(parts, ", ")
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

// Items is the wallpaper and the screen saver page, as the target sets them.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	l, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var items []provider.Item
	if l.wallpaper.set {
		items = append(items, provider.Item{Name: filepath.Base(t.Wallpaper), Kind: "wallpaper", State: l.wallpaper.state, Desc: l.wallpaper.detail})
	}
	if l.screensaver.set {
		items = append(items, provider.Item{Name: filepath.Base(t.Screensaver), Kind: "screensaver", State: l.screensaver.state,
			App: "WebViewScreenSaver", Desc: l.screensaver.detail})
	}
	return items, nil
}

func (Provider) Programs(t config.Target) []string {
	var progs []string
	if t.Wallpaper != "" {
		progs = append(progs, "osascript")
	}
	if t.Screensaver != "" {
		progs = append(progs, "defaults", "ioreg")
	}
	return progs
}
