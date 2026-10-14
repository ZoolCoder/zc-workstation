package ui

import (
	"net/http"
	"slices"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/engine"
)

// itemRow is one inventory row: an item and the target that declares it.
type itemRow struct {
	engine.Item
	Target string
}

// Search is what the table's search box matches against.
func (r itemRow) Search() string {
	return strings.ToLower(strings.Join([]string{r.Target, r.Kind, r.Name, r.State, r.Version, r.Latest, r.App, r.Desc}, " "))
}

// configured is one program the dotfiles configure.
type configured struct {
	App           string
	Files, Behind int
}

// group counts one kind of item: how many are in place.
type group struct{ InPlace, Total int }

func (g *group) add(i engine.Item) {
	g.Total++
	if installed(i) {
		g.InPlace++
	}
}

// installed is in place, whether or not a newer version exists.
func installed(i engine.Item) bool { return i.State == engine.InPlace || i.State == engine.Outdated }

type inventoryPage struct {
	chrome
	ConfigErr error
	Rows      []itemRow
	// Unread are targets with no items here: skipped, or failed to read.
	Unread []engine.TargetItems
	Apps   []configured
	// Tools are command-line packages, Desktop are applications.
	Tools, Desktop, Dotfiles, Runtimes group
	// Behind is declared items not in place; Outdated have an update, and
	// Extra are installed but declared by no target.
	Behind, Outdated, Extra int
}

// appKinds are the package kinds that install desktop applications.
var appKinds = []string{"cask", "mas", "winget"}

func (s *Server) inventory(w http.ResponseWriter, r *http.Request) {
	p := inventoryPage{chrome: s.chrome(r, "inventory")}
	p.Title = p.T("Inventory")
	eng, err := s.engine()
	if err == nil {
		c, cancel := ctx(r)
		defer cancel()
		p.fill(eng.Items(c))
	}
	p.ConfigErr = err
	s.render(w, "inventory.html", p)
}

func (p *inventoryPage) fill(targets []engine.TargetItems) {
	apps := map[string]*configured{}
	for _, t := range targets {
		if t.Skipped || t.Error != "" {
			p.Unread = append(p.Unread, t)
		}
		for _, i := range t.Items {
			p.Rows = append(p.Rows, itemRow{Item: i, Target: t.Target})
			switch i.State {
			case engine.Extra:
				p.Extra++
				continue
			case engine.Outdated:
				p.Outdated++
			case engine.InPlace:
			default:
				p.Behind++
			}
			switch {
			case i.Kind == "dotfile":
				p.Dotfiles.add(i)
				a, ok := apps[i.App]
				if !ok {
					a = &configured{App: i.App}
					apps[i.App] = a
				}
				a.Files++
				if !installed(i) {
					a.Behind++
				}
			case i.Kind == "runtime":
				p.Runtimes.add(i)
			case slices.Contains(appKinds, i.Kind):
				p.Desktop.add(i)
			case i.Kind != "tap" && i.Kind != "script" && i.Kind != "file":
				p.Tools.add(i)
			}
		}
	}
	for _, a := range apps {
		p.Apps = append(p.Apps, *a)
	}
	slices.SortFunc(p.Apps, func(a, b configured) int { return strings.Compare(a.App, b.App) })
}

func stateChip(state string) string {
	switch state {
	case engine.InPlace:
		return "on"
	case engine.Missing:
		return "warn"
	case engine.Differs:
		return "bad"
	case engine.Outdated:
		return "violet"
	case engine.Extra:
		return "plain"
	}
	return "zero"
}
