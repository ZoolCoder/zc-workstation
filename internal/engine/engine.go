// Package engine turns a config plus live state into one plan, applies it,
// and re-plans to verify the apply converged.
package engine

import (
	"context"
	"fmt"
	"io"
	"runtime"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/provider/desktop"
	"github.com/zoolcoder/zc-workstation/internal/provider/dotfiles"
	"github.com/zoolcoder/zc-workstation/internal/provider/localdir"
	"github.com/zoolcoder/zc-workstation/internal/provider/packages"
	"github.com/zoolcoder/zc-workstation/internal/provider/tools"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// GOOS is the system targets are matched against; tests change it.
var GOOS = runtime.GOOS

// Providers maps a config provider name to its implementation.
type Providers map[string]provider.Provider

// Default is every built-in provider, driving this machine's programs.
func Default() Providers { return With(sh.System()) }

// With is every built-in provider, driving programs through r.
func With(r sh.Runner) Providers {
	return Providers{
		"localdir": localdir.New(),
		"packages": packages.New(r, GOOS),
		"dotfiles": dotfiles.New(r),
		"tools":    tools.New(r),
		"desktop":  desktop.New(r),
	}
}

type Engine struct {
	cfg       config.Config
	providers Providers
	targets   []config.Target
}

// New selects the named targets, or every target when names is empty.
func New(cfg config.Config, providers Providers, names []string) (*Engine, error) {
	targets, err := Select(cfg, names)
	if err != nil {
		return nil, err
	}
	return &Engine{cfg: cfg, providers: providers, targets: targets}, nil
}

// Select returns the named targets with their paths resolved, in config
// order. An unknown name is an error, not an empty plan.
func Select(cfg config.Config, names []string) ([]config.Target, error) {
	for _, n := range names {
		if _, ok := cfg.Find(n); !ok {
			return nil, fmt.Errorf("no target named %q in the config", n)
		}
	}
	var out []config.Target
	for _, t := range cfg.Targets {
		if len(names) == 0 || slices.Contains(names, t.Name) {
			t = cfg.Resolve(t)
			out = append(out, t)
		}
	}
	return out, nil
}

func (e *Engine) provider(t config.Target) (provider.Provider, error) {
	p, ok := e.providers[t.Provider]
	if !ok {
		return nil, fmt.Errorf("target %s: provider %q is not available in this build", t.Name, t.Provider)
	}
	return p, nil
}

// Plan reads live state for every selected target that applies to this
// system.
func (e *Engine) Plan(ctx context.Context) (plan.Plan, error) {
	var p plan.Plan
	for _, t := range e.targets {
		if !t.ForOS(GOOS) {
			continue
		}
		prov, err := e.provider(t)
		if err != nil {
			return plan.Plan{}, err
		}
		actions, err := prov.Plan(ctx, t)
		if err != nil {
			return plan.Plan{}, fmt.Errorf("plan %s: %w", t.Name, err)
		}
		p.Add(actions...)
	}
	return p, nil
}

// Apply runs every executable action in order and stops at the first
// failure. Then it re-plans: an action that reported success but left the
// target still different is a failure too.
func (e *Engine) Apply(ctx context.Context, p plan.Plan, w io.Writer) error {
	for _, a := range p.Executable() {
		if err := a.Do(ctx); err != nil {
			return fmt.Errorf("%s %s %s: %w", a.Op, a.Target, a.Resource, err)
		}
		fmt.Fprintf(w, "done  %s %s %s\n", a.Op, a.Target, a.Resource)
	}
	after, err := e.Plan(ctx)
	if err != nil {
		return fmt.Errorf("verify: %w", err)
	}
	if left := after.Executable(); len(left) > 0 {
		return fmt.Errorf("applied, but %d change(s) are still outstanding; run plan to see them", len(left))
	}
	_, err = fmt.Fprintln(w, "applied and verified")
	return err
}

// TargetStatus is one target's live summary. InPlace and Declared are set
// when the provider can count; Skipped means the target is for other systems.
type TargetStatus struct {
	Target   string `json:"target"`
	Provider string `json:"provider"`
	Summary  string `json:"summary"`
	InPlace  int    `json:"in_place"`
	Declared int    `json:"declared"`
	Skipped  bool   `json:"skipped,omitempty"`
	Error    string `json:"error,omitempty"`
}

// InSync reports whether everything the target declares is in place.
func (s TargetStatus) InSync() bool {
	return !s.Skipped && s.Error == "" && s.InPlace == s.Declared
}

// Status summarises every selected target. A target that cannot be read is
// reported in its row rather than failing the others.
func (e *Engine) Status(ctx context.Context) []TargetStatus {
	out := make([]TargetStatus, 0, len(e.targets))
	for _, t := range e.targets {
		row := TargetStatus{Target: t.Name, Provider: t.Provider}
		if !t.ForOS(GOOS) {
			row.Skipped = true
			row.Summary = "not for " + GOOS + ", only " + strings.Join(t.OS, ", ")
			out = append(out, row)
			continue
		}
		prov, err := e.provider(t)
		if err == nil {
			if m, ok := prov.(provider.Measurer); ok {
				var live provider.Live
				live, err = m.Measure(ctx, t)
				row.Summary, row.InPlace, row.Declared = live.Summary, live.InPlace, live.Declared
			} else {
				row.Summary, err = prov.Status(ctx, t)
			}
		}
		if err != nil {
			row.Error = err.Error()
		}
		out = append(out, row)
	}
	return out
}

// Programs lists, sorted and once each, the programs the selected targets for
// this system need.
func (e *Engine) Programs() []string {
	var out []string
	for _, t := range e.targets {
		if !t.ForOS(GOOS) {
			continue
		}
		if r, ok := e.providers[t.Provider].(provider.Requirer); ok {
			out = append(out, r.Programs(t)...)
		}
	}
	slices.Sort(out)
	return slices.Compact(out)
}

// Item and its states are re-exported so the dashboard reads them through
// the engine, never a provider package.
type Item = provider.Item

const (
	InPlace  = provider.InPlace
	Missing  = provider.Missing
	Differs  = provider.Differs
	Manual   = provider.Manual
	Outdated = provider.Outdated
	Extra    = provider.Extra
)

// TargetItems is one target's inventory: what it declares, item by item.
type TargetItems struct {
	Target   string          `json:"target"`
	Provider string          `json:"provider"`
	Items    []provider.Item `json:"items"`
	Skipped  bool            `json:"skipped,omitempty"`
	Error    string          `json:"error,omitempty"`
}

// Items lists every selected target's items. Like Status, a target that
// cannot be read reports it in its row.
func (e *Engine) Items(ctx context.Context) []TargetItems {
	// Targets read different programs, so they are read side by side.
	out := make([]TargetItems, len(e.targets))
	var wg sync.WaitGroup
	for n, t := range e.targets {
		wg.Go(func() { out[n] = e.items(ctx, t) })
	}
	wg.Wait()
	return dropDeclaredExtras(out)
}

func (e *Engine) items(ctx context.Context, t config.Target) TargetItems {
	row := TargetItems{Target: t.Name, Provider: t.Provider, Items: []provider.Item{}}
	if !t.ForOS(GOOS) {
		row.Skipped = true
		return row
	}
	prov, err := e.provider(t)
	if err == nil {
		if l, ok := prov.(provider.Lister); ok {
			row.Items, err = l.Items(ctx, t)
		} else {
			err = fmt.Errorf("provider %s cannot list its items", t.Provider)
		}
	}
	if err != nil {
		row.Error = err.Error()
	}
	return row
}

// dropDeclaredExtras keeps an Extra item only if no target declares it and
// no earlier target already listed it: two Brewfile targets each see the
// other's packages as undeclared.
func dropDeclaredExtras(rows []TargetItems) []TargetItems {
	seen := map[string]bool{}
	for _, r := range rows {
		for _, i := range r.Items {
			if i.State != provider.Extra {
				seen[itemKey(i)] = true
			}
		}
	}
	for n, r := range rows {
		kept := r.Items[:0]
		for _, i := range r.Items {
			if i.State == provider.Extra {
				if seen[itemKey(i)] {
					continue
				}
				seen[itemKey(i)] = true
			}
			kept = append(kept, i)
		}
		rows[n].Items = kept
	}
	return rows
}

// itemKey names an item across targets: its kind and short name, and for a
// runtime its version too, since each version is its own item.
func itemKey(i provider.Item) string {
	name := strings.ToLower(i.Name)
	key := i.Kind + ":" + name[strings.LastIndex(name, "/")+1:]
	if i.Kind == "runtime" {
		key += "@" + i.Version
	}
	return key
}

// Capture writes the manifest the one selected target would declare to
// match this machine.
func (e *Engine) Capture(ctx context.Context) (config.Target, []byte, error) {
	if len(e.targets) != 1 {
		return config.Target{}, nil, fmt.Errorf("capture needs exactly one target, %d selected; use -target", len(e.targets))
	}
	t := e.targets[0]
	if !t.ForOS(GOOS) {
		return t, nil, fmt.Errorf("target %s is not for this system", t.Name)
	}
	prov, err := e.provider(t)
	if err != nil {
		return t, nil, err
	}
	c, ok := prov.(provider.Capturer)
	if !ok {
		return t, nil, fmt.Errorf("provider %s cannot capture", t.Provider)
	}
	data, err := c.Capture(ctx, t)
	return t, data, err
}
