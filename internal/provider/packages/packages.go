// Package packages installs what a manifest declares with the system's package
// manager: a Brewfile for Homebrew, a plain list for apt or dnf, a winget
// import file for winget. It only installs. A package the manifest drops is
// left in place, because removing software is a decision for a person.
package packages

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/manifest"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// Provider reads and installs packages through r.
type Provider struct {
	r    sh.Runner
	goos string
}

func New(r sh.Runner, goos string) Provider { return Provider{r: r, goos: goos} }

// item is one declared package. Kind is the manifest's word for it (brew,
// cask, tap, mas, apt, dnf, winget); ID is the App Store id for mas.
type item struct {
	Kind, Name, ID string
}

func (i item) resource() string { return i.Kind + ":" + i.Name }

// manager is one package manager: how to read its manifest, list what is
// installed, and install one item.
type manager struct {
	program string
	parse   func(data []byte) (items []item, unsupported []string, err error)
	// installed lists what is in place, keyed by kind; a kind with no entry
	// could not be read, and its items become MANUAL with the reason.
	installed func(ctx context.Context, r sh.Runner, items []item) (map[string]set, map[string]string, error)
	install   func(r sh.Runner, i item) func(context.Context) error
	// details reads versions and descriptions for the inventory; nil when
	// the manager has no cheap way to say.
	details func(ctx context.Context, r sh.Runner) (details, error)
	// chosen lists what a person installed on purpose, declared or not, for
	// the inventory's extras and for capture; nil when the manager cannot say.
	chosen func(ctx context.Context, r sh.Runner) ([]item, error)
	// outdated reads pending updates, and upgrade applies one; nil when the
	// manager cannot say.
	outdated func(ctx context.Context, r sh.Runner) (updates, error)
	upgrade  func(r sh.Runner, i item) func(context.Context) error
	// key reads an entry line for its manifest comments, and entry writes
	// one, with kind defaulted and checked; nil when the manifest is not
	// line-based.
	key   manifest.Key
	entry func(kind, name string) (string, string, error)
}

// Manager is the package manager t uses on this system.
func (p Provider) Manager(t config.Target) string {
	if t.Manager != "" {
		return t.Manager
	}
	switch p.goos {
	case "darwin":
		return "brew"
	case "windows":
		return "winget"
	}
	if !p.r.Has("apt-get") && p.r.Has("dnf") {
		return "dnf"
	}
	return "apt"
}

// state is what Plan and Measure share: the manifest and what is missing.
type state struct {
	manager     string
	items       []item
	unsupported []string
	missing     []item
	manual      []plan.Action
	declared    int
	// notes are the manifest comments about each item, by resource.
	notes map[string]manifest.Note
}

func (p Provider) read(ctx context.Context, t config.Target) (state, error) {
	name := p.Manager(t)
	m := managers[name]
	s := state{manager: name}
	data, err := readFile(t.File)
	if err != nil {
		return s, err
	}
	items, unsupported, err := m.parse(data)
	if err != nil {
		return s, fmt.Errorf("%s: %w", t.File, err)
	}
	s.items, s.unsupported = items, unsupported
	if m.key != nil {
		s.notes = manifest.Notes(data, m.key)
	}
	for _, line := range unsupported {
		s.manual = append(s.manual, manual(t, "unsupported:"+line, "zc-workstation does not install this kind of entry; install it by hand"))
	}
	if !p.r.Has(m.program) {
		return s, errMissing{name: name, program: m.program}
	}
	have, unreadable, err := m.installed(ctx, p.r, items)
	if err != nil {
		return s, err
	}
	for _, i := range items {
		if reason, ok := unreadable[i.Kind]; ok {
			s.manual = append(s.manual, manual(t, i.resource(), reason))
			continue
		}
		s.declared++
		if !have[i.Kind].has(i) {
			s.missing = append(s.missing, i)
		}
	}
	return s, nil
}

// errMissing is a package manager that is not installed.
type errMissing struct{ name, program string }

func (e errMissing) Error() string {
	return e.program + " is not on PATH; install " + e.name + " first"
}

// Plan installs each declared package that is missing. If the package
// manager itself is missing, the plan is one MANUAL step to install it.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	s, err := p.read(ctx, t)
	if missing := (errMissing{}); errors.As(err, &missing) {
		return []plan.Action{manual(t, missing.name, missing.Error())}, nil
	}
	if err != nil {
		return nil, err
	}
	m := managers[s.manager]
	actions := s.manual
	for _, i := range s.missing {
		actions = append(actions, plan.Action{
			Op: plan.OpCreate, Target: t.Name, Resource: i.resource(),
			Detail: "install with " + installer(s.manager, i), Do: m.install(p.r, i),
		})
	}
	if t.Upgrade {
		actions = append(actions, p.upgrades(ctx, t, s)...)
	}
	return actions, nil
}

// upgrades is one UPDATE per installed, declared package with a newer
// version. A manager that cannot tell is one MANUAL step saying so.
func (p Provider) upgrades(ctx context.Context, t config.Target, s state) []plan.Action {
	m := managers[s.manager]
	if m.outdated == nil {
		return []plan.Action{manual(t, "upgrade", s.manager+" cannot list updates here; upgrade by hand")}
	}
	u, err := m.outdated(ctx, p.r)
	if err != nil {
		return []plan.Action{manual(t, "upgrade", "cannot read updates: "+err.Error())}
	}
	var actions []plan.Action
	for _, i := range s.installed() {
		if v, ok := lookup(u, i); ok {
			actions = append(actions, plan.Action{
				Op: plan.OpUpdate, Target: t.Name, Resource: i.resource(),
				Detail: fmt.Sprintf("upgrade with %s, %s to %s", installer(s.manager, i), dash(v.From), v.To),
				Do:     m.upgrade(p.r, i),
			})
		}
	}
	return actions
}

// installed is the declared items that are in place.
func (s state) installed() []item {
	gone := map[string]bool{}
	for _, i := range s.missing {
		gone[i.resource()] = true
	}
	for _, a := range s.manual {
		gone[a.Resource] = true
	}
	var out []item
	for _, i := range s.items {
		if !gone[i.resource()] && i.Kind != "tap" {
			out = append(out, i)
		}
	}
	return out
}

func dash(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

// Measure counts the declared packages that are installed.
func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	s, err := p.read(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: s.declared, InPlace: s.declared - len(s.missing)}
	live.Summary = fmt.Sprintf("%d of %d packages installed (%s)", live.InPlace, live.Declared, s.manager)
	if len(s.manual) > 0 {
		live.Summary += fmt.Sprintf(", %d manual", len(s.manual))
	}
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

func installer(manager string, i item) string {
	if i.Kind == "mas" {
		return "mas"
	}
	return manager
}

func manual(t config.Target, resource, detail string) plan.Action {
	return plan.Action{Op: plan.OpManual, Target: t.Name, Resource: resource, Detail: detail}
}

// set holds installed names, compared without case.
type set map[string]bool

func newSet(names ...string) set {
	s := set{}
	for _, n := range names {
		if n = strings.TrimSpace(n); n != "" {
			s[strings.ToLower(n)] = true
		}
	}
	return s
}

// has matches by full name, and for a tapped formula or cask by its short
// name too, since brew lists core packages without their tap.
func (s set) has(i item) bool {
	key := strings.ToLower(i.Name)
	if i.ID != "" {
		key = i.ID
	}
	if s[key] {
		return true
	}
	if i.Kind == "brew" || i.Kind == "cask" {
		return s[key[strings.LastIndex(key, "/")+1:]]
	}
	return false
}

func lines(out []byte) []string { return strings.Split(strings.TrimSpace(string(out)), "\n") }

// Programs is the package manager t needs.
func (p Provider) Programs(t config.Target) []string {
	return []string{managers[p.Manager(t)].program}
}
