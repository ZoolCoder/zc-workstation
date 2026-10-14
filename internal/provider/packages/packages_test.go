package packages

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

const brewfile = `# taps come first in the plan even when listed last
brew "git"
brew "FelixKratz/formulae/sketchybar"
cask "ghostty"
mas "Bitwarden", id: 1352778147
mas "uBlock Origin Lite", id: 6745342698
vscode "golang.go"
tap "felixkratz/formulae"
tap "hashicorp/tap"
`

func manifest(t *testing.T, name, body string) config.Target {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return config.Target{Name: "pkgs", Provider: "packages", File: path}
}

func brewMachine() *sh.Fake {
	return &sh.Fake{
		Programs: []string{"brew", "mas"},
		Out: map[string]string{
			"brew list --formula -1 --full-name": "git\nfelixkratz/formulae/sketchybar\n",
			"brew list --cask -1 --full-name":    "",
			"brew tap":                           "FelixKratz/formulae\n",
			"mas list":                           "1352778147  Bitwarden  (2026.9.1)\n",
		},
	}
}

func resources(actions []plan.Action) []string {
	var out []string
	for _, a := range actions {
		out = append(out, string(a.Op)+" "+a.Resource)
	}
	return out
}

func TestBrewPlanInstallsWhatIsMissing(t *testing.T) {
	r := brewMachine()
	tg := manifest(t, "Brewfile", brewfile)
	actions, err := New(r, "darwin").Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(resources(actions), ", ")
	want := "MANUAL unsupported:vscode:golang.go, CREATE tap:hashicorp/tap, CREATE cask:ghostty, CREATE mas:uBlock Origin Lite"
	if got != want {
		t.Fatalf("plan\n got %s\nwant %s", got, want)
	}
	for _, a := range actions {
		if a.Do != nil {
			if err := a.Do(context.Background()); err != nil {
				t.Fatal(err)
			}
		}
	}
	ran := strings.Join(r.Ran, "\n")
	if ran != "brew tap hashicorp/tap\nbrew install --cask ghostty\nmas install 6745342698" {
		t.Fatalf("ran\n%s", ran)
	}
}

func TestBrewMeasure(t *testing.T) {
	live, err := New(brewMachine(), "darwin").Measure(context.Background(), manifest(t, "Brewfile", brewfile))
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 4 || live.Declared != 7 || live.Summary != "4 of 7 packages installed (brew), 1 manual" {
		t.Fatalf("live %+v", live)
	}
}

func TestMasMissingMakesAppStoreAppsManual(t *testing.T) {
	r := brewMachine()
	r.Programs = []string{"brew"}
	actions, err := New(r, "darwin").Plan(context.Background(), manifest(t, "Brewfile", `mas "Bitwarden", id: 1352778147`))
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || !strings.Contains(actions[0].Detail, "brew install mas") {
		t.Fatalf("plan %+v %v", actions, err)
	}
}

func TestMissingManagerIsOneManualStep(t *testing.T) {
	actions, err := New(&sh.Fake{}, "darwin").Plan(context.Background(), manifest(t, "Brewfile", brewfile))
	if err != nil || len(actions) != 1 || actions[0].Op != plan.OpManual || actions[0].Resource != "brew" {
		t.Fatalf("plan %+v %v", actions, err)
	}
	if _, err := New(&sh.Fake{}, "darwin").Measure(context.Background(), manifest(t, "Brewfile", brewfile)); err == nil {
		t.Fatal("measured without brew")
	}
}

func TestBadBrewfile(t *testing.T) {
	for _, body := range []string{"brew git\n", `mas "Bitwarden"`} {
		if _, err := New(brewMachine(), "darwin").Plan(context.Background(), manifest(t, "Brewfile", body)); err == nil {
			t.Errorf("accepted %q", body)
		}
	}
}

func TestApt(t *testing.T) {
	r := &sh.Fake{
		Programs: []string{"apt-get"},
		Out: map[string]string{
			"dpkg-query -W -f ${db:Status-Abbrev}\t${Package}": "ii \tgit\nrc \tzsh\nii \ttmux\n",
		},
	}
	tg := manifest(t, "apt.txt", "git\nzsh # removed but configs left: rc, not installed\n\ntmux\n")
	p := New(r, "linux")
	if m := p.Manager(tg); m != "apt" {
		t.Fatalf("manager %s", m)
	}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil || strings.Join(resources(actions), ",") != "CREATE apt:zsh" {
		t.Fatalf("plan %v %v", resources(actions), err)
	}
	_ = actions[0].Do(context.Background())
	if r.Ran[0] != "sudo apt-get install -y zsh" {
		t.Fatalf("ran %v", r.Ran)
	}
}

func TestDnfIsPickedWhenAptIsAbsent(t *testing.T) {
	r := &sh.Fake{Programs: []string{"dnf"}, Out: map[string]string{"rpm -qa --qf %{NAME}": "git\n"}}
	tg := manifest(t, "dnf.txt", "git\nfish\n")
	p := New(r, "linux")
	if m := p.Manager(tg); m != "dnf" {
		t.Fatalf("manager %s", m)
	}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil || strings.Join(resources(actions), ",") != "CREATE dnf:fish" {
		t.Fatalf("plan %v %v", resources(actions), err)
	}
}

func TestWinget(t *testing.T) {
	r := &sh.Fake{
		Programs: []string{"winget"},
		Out:      map[string]string{"winget list --id Git.Git --exact --accept-source-agreements --disable-interactivity": "Git  Git.Git  2.47"},
		Err:      map[string]error{"winget list --id wez.wezterm --exact --accept-source-agreements --disable-interactivity": errors.New("exit status 1")},
	}
	tg := manifest(t, "winget.json", `{"Sources":[{"Packages":[{"PackageIdentifier":"Git.Git"},{"PackageIdentifier":"wez.wezterm"}]}]}`)
	actions, err := New(r, "windows").Plan(context.Background(), tg)
	if err != nil || strings.Join(resources(actions), ",") != "CREATE winget:wez.wezterm" {
		t.Fatalf("plan %v %v", resources(actions), err)
	}
	_ = actions[0].Do(context.Background())
	if !strings.HasPrefix(r.Ran[0], "winget install --id wez.wezterm --exact --silent") {
		t.Fatalf("ran %v", r.Ran)
	}
}

func TestExplicitManagerWins(t *testing.T) {
	tg := config.Target{Manager: "brew"}
	if m := New(&sh.Fake{}, "linux").Manager(tg); m != "brew" {
		t.Fatalf("manager %s", m)
	}
}

func TestItemsCarryStateVersionAndDescription(t *testing.T) {
	r := brewMachine()
	r.Out["brew info --json=v2 --installed"] = `{
		"formulae": [{"name": "git", "full_name": "git", "desc": "Distributed revision control system",
			"homepage": "https://git-scm.com", "installed": [{"version": "2.56.0"}]},
			{"name": "sketchybar", "full_name": "felixkratz/formulae/sketchybar", "desc": "Custom macOS statusbar",
			"installed": [{"version": "2.22.1"}]}],
		"casks": []}`
	items, err := New(r, "darwin").Items(context.Background(), manifest(t, "Brewfile", brewfile))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, i := range items {
		got = append(got, strings.Join([]string{i.Kind, i.Name, i.State, i.Version, i.App, i.Desc}, "|"))
	}
	want := []string{
		"tap|felixkratz/formulae|in place|||",
		"tap|hashicorp/tap|missing|||",
		"brew|git|in place|2.56.0||Distributed revision control system",
		"brew|FelixKratz/formulae/sketchybar|in place|2.22.1||Custom macOS statusbar",
		"cask|ghostty|missing|||",
		"mas|Bitwarden|in place|2026.9.1|Bitwarden|",
		"mas|uBlock Origin Lite|missing|||",
		"vscode|golang.go|manual|||zc-workstation does not install this kind of entry",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("items\n%s", strings.Join(got, "\n"))
	}
}

func TestItemsWithoutDetailsStillList(t *testing.T) {
	r := brewMachine() // no brew info answer: details fail, items do not
	items, err := New(r, "darwin").Items(context.Background(), manifest(t, "Brewfile", `brew "git"`))
	if err != nil || len(items) != 1 || items[0].State != "in place" || items[0].Version != "" {
		t.Fatalf("items %+v %v", items, err)
	}
}

func TestAptItemsReadDpkg(t *testing.T) {
	r := &sh.Fake{Programs: []string{"apt-get"}, Out: map[string]string{
		"dpkg-query -W -f ${db:Status-Abbrev}\t${Package}":                        "ii \tgit\n",
		"dpkg-query -W -f ${Package}\t${Version}\t${binary:Summary}\t${Homepage}": "git\t1:2.43.0\tfast, scalable, distributed revision control system\thttps://git-scm.com/\n",
	}}
	items, err := New(r, "linux").Items(context.Background(), manifest(t, "apt.txt", "git\ncurl\n"))
	if err != nil || len(items) != 2 || items[0].Version != "1:2.43.0" || items[0].Homepage != "https://git-scm.com/" || items[1].State != "missing" {
		t.Fatalf("items %+v %v", items, err)
	}
}
