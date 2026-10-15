package settings

import (
	"context"
	"slices"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

func target() config.Target {
	return config.Target{Name: "macos", Provider: "settings", OS: []string{"darwin"}, Defaults: map[string]map[string]any{
		"NSGlobalDomain":          {"KeyRepeat": 2, "NSWindowResizeTime": 0.001, "ApplePressAndHoldEnabled": false},
		"com.apple.dock":          {"autohide": true},
		"com.apple.screencapture": {"location": "~/Screenshots"},
	}}
}

func read(domain, key string) string { return sh.Line("defaults", "read", domain, key) }

// machine has KeyRepeat and the resize time as declared, the press-and-hold
// popup on, and neither the Dock nor the screenshot key set.
func machine() *sh.Fake {
	return &sh.Fake{Out: map[string]string{
		read("NSGlobalDomain", "KeyRepeat"):                "2\n",
		read("NSGlobalDomain", "NSWindowResizeTime"):       "0.0010\n",
		read("NSGlobalDomain", "ApplePressAndHoldEnabled"): "1\n",
	}}
}

func TestPlanWritesWhatDiffersAndRestartsReaders(t *testing.T) {
	r := machine()
	p := Provider{r: r, home: "/Users/me"}
	actions, err := p.Plan(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, string(a.Op)+" "+a.Resource)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		string(plan.OpUpdate) + " NSGlobalDomain ApplePressAndHoldEnabled",
		string(plan.OpCreate) + " com.apple.dock autohide",
		string(plan.OpCreate) + " com.apple.screencapture location",
		string(plan.OpUpdate) + " restart Dock",
		string(plan.OpUpdate) + " restart SystemUIServer",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{
		"defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false",
		"defaults write com.apple.dock autohide -bool true",
		"defaults write com.apple.screencapture location -string /Users/me/Screenshots",
		"killall Dock",
		"killall SystemUIServer",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
}

func TestMeasureCountsKeysInPlace(t *testing.T) {
	p := Provider{r: machine(), home: "/Users/me"}
	live, err := p.Measure(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 2 || live.Declared != 5 {
		t.Fatalf("live %+v", live)
	}
	items, _ := p.Items(context.Background(), target())
	if items[0].Name != "NSGlobalDomain ApplePressAndHoldEnabled" || items[0].State != provider.Differs || items[0].Version != "1" {
		t.Fatalf("first item %+v", items[0])
	}
}

func TestSame(t *testing.T) {
	for _, c := range []struct {
		want any
		have string
		same bool
	}{
		{true, "1", true}, {false, "0", true}, {true, "0", false}, {false, "", false},
		{15, "15", true}, {15, "15.0", false}, {0.15, "0.15000", true}, {0.15, "0.1500000059604645", true}, {0.15, "0.16", false}, {0.0, "0", true},
		{"Nlsv", "Nlsv", true}, {"Nlsv", "icnv", false},
	} {
		if got := same(c.want, c.have); got != c.same {
			t.Errorf("same(%v, %q) = %v", c.want, c.have, got)
		}
	}
}

func TestPlanSetsGnomeKeys(t *testing.T) {
	get := func(schema, key string) string { return sh.Line("gsettings", "get", schema, key) }
	r := &sh.Fake{Out: map[string]string{
		get("org.gnome.desktop.interface", "color-scheme"):        "'default'\n",
		get("org.gnome.desktop.interface", "text-scaling-factor"): "1.25\n",
		get("org.gnome.desktop.peripherals.keyboard", "delay"):    "uint32 500\n",
		get("org.gnome.shell", "favorite-apps"):                   "['firefox.desktop']\n",
	}}
	p := Provider{r: r, home: "/home/me"}
	tg := config.Target{Name: "gnome", Provider: "settings", OS: []string{"linux"}, Gsettings: map[string]map[string]any{
		"org.gnome.desktop.interface":            {"color-scheme": "prefer-dark", "text-scaling-factor": 1.25},
		"org.gnome.desktop.peripherals.keyboard": {"delay": 500},
		"org.gnome.shell":                        {"favorite-apps": []any{"firefox.desktop", "org.gnome.Terminal.desktop"}},
	}}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range actions {
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	ran := []string{
		"gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'",
		"gsettings set org.gnome.shell favorite-apps ['firefox.desktop', 'org.gnome.Terminal.desktop']",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
	if got := p.Programs(tg); !slices.Equal(got, []string{"gsettings"}) {
		t.Fatalf("programs %v", got)
	}
}

func TestSameGVariant(t *testing.T) {
	for _, c := range []struct {
		want any
		have string
		same bool
	}{
		{true, "true", true}, {false, "true", false}, {5, "uint32 5", true}, {5, "int64 6", false},
		{1.0, "1.0", true}, {0.5, "0.5", true}, {"x", "'x'", true}, {"it's", `"it's"`, true}, {"x", "'y'", false},
		{[]any{"a", "b"}, "['a', 'b']", true}, {[]any{}, "@as []", true}, {[]any{"a"}, "@as []", false},
	} {
		if got := sameGVariant(c.want, c.have); got != c.same {
			t.Errorf("sameGVariant(%v, %q) = %v", c.want, c.have, got)
		}
	}
	if got := gvariant(`a'b\c`); got != `'a\'b\\c'` {
		t.Errorf("gvariant quoting %s", got)
	}
}
