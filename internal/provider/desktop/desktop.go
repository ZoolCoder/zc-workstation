// Package desktop sets the macOS desktop picture and the page the
// WebViewScreenSaver screen saver shows. System Events sets the picture. The
// page goes into the saver's own Info.plist as its default address, because
// macOS keeps the saver's preferences in a container no terminal may open, and
// the sandboxed saver cannot read files outside its bundle.
package desktop

import (
	"context"
	"encoding/base64"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// Saver is the screen saver bundle the screensaver key needs, built and
// installed by assets/screensaver/build-saver.sh.
const Saver = "WebViewScreenSaver.saver"

// defaultURLKey is the Info.plist key holding the page the saver shows while
// its own list of pages is empty.
const defaultURLKey = "WVSSDefaultAddressURL"

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
	// saver is the installed saver bundle, and page the page as a data URL,
	// when the screensaver key is set.
	saver, page string
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
		s, saver, page, err := p.readScreensaver(ctx, t.Screensaver)
		if err != nil {
			return l, err
		}
		l.screensaver, l.saver, l.page = s, saver, page
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

func (p Provider) readScreensaver(ctx context.Context, path string) (state, string, string, error) {
	if _, err := os.Stat(path); err != nil {
		return state{set: true, state: provider.Missing, detail: "no page at " + path}, "", "", nil
	}
	saver := p.installedSaver()
	if saver == "" {
		return state{set: true, state: provider.Missing, resource: "webviewscreensaver",
			detail: "install the saver: run assets/screensaver/build-saver.sh from zc-workstation (needs Xcode)"}, "", "", nil
	}
	page, err := dataURL(path)
	if err != nil {
		return state{}, "", "", err
	}
	// A fresh build holds the upstream default address, so it differs.
	out, err := p.r.Output(ctx, "plutil", "-extract", defaultURLKey, "raw", "-o", "-", infoPlist(saver))
	if err == nil && strings.TrimSpace(string(out)) == page {
		return state{set: true, state: provider.InPlace, detail: "WebViewScreenSaver shows it"}, saver, page, nil
	}
	return state{set: true, state: provider.Differs, detail: "WebViewScreenSaver shows another page"}, saver, page, nil
}

func infoPlist(saver string) string { return filepath.Join(saver, "Contents/Info.plist") }

func (p Provider) installedSaver() string {
	for _, lib := range []string{filepath.Join(p.home, "Library"), p.system} {
		saver := filepath.Join(lib, "Screen Savers", Saver)
		if info, err := os.Stat(saver); err == nil && info.IsDir() {
			return saver
		}
	}
	return ""
}

// localRef is a relative url() in the page's CSS, such as a font beside it.
var localRef = regexp.MustCompile(`url\(([\w./-]+\.\w+)\)`)

// dataURL is the page as one data URL, with the files its CSS loads from its
// folder inlined, so the saver needs no file access.
func dataURL(path string) (string, error) {
	page, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	var readErr error
	page = localRef.ReplaceAllFunc(page, func(ref []byte) []byte {
		name := string(localRef.FindSubmatch(ref)[1])
		b, err := os.ReadFile(filepath.Join(filepath.Dir(path), name))
		if err != nil {
			readErr = err
			return ref
		}
		return []byte("url(data:" + mediaType(name) + ";base64," + base64.StdEncoding.EncodeToString(b) + ")")
	})
	if readErr != nil {
		return "", fmt.Errorf("inline into %s: %w", filepath.Base(path), readErr)
	}
	return "data:text/html;base64," + base64.StdEncoding.EncodeToString(page), nil
}

func mediaType(name string) string {
	if filepath.Ext(name) == ".woff2" {
		return "font/woff2"
	}
	if t := mime.TypeByExtension(filepath.Ext(name)); t != "" {
		return t
	}
	return "application/octet-stream"
}

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
		actions = append(actions, plan.Action{Op: plan.OpUpdate, Target: t.Name, Resource: "screensaver",
			Detail: "show " + filepath.Base(t.Screensaver) + " in WebViewScreenSaver; pick it once in System Settings, Screen Saver",
			Do: func(ctx context.Context) error {
				if err := p.r.Run(ctx, "plutil", "-replace", defaultURLKey, "-string", l.page, infoPlist(l.saver)); err != nil {
					return err
				}
				// Editing Info.plist breaks the bundle's seal; sign it again, ad hoc as built.
				return p.r.Run(ctx, "codesign", "--force", "--sign", "-", l.saver)
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
		progs = append(progs, "plutil", "codesign")
	}
	return progs
}
