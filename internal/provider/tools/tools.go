// Package tools installs the language runtimes a mise config declares. mise
// resolves versions and installs; this provider asks it what is missing from
// one config file and turns each gap into a plan action.
package tools

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

type Provider struct{ r sh.Runner }

func New(r sh.Runner) Provider { return Provider{r: r} }

// version is one entry of `mise ls --json`.
type version struct {
	Version          string `json:"version"`
	RequestedVersion string `json:"requested_version"`
	Installed        bool   `json:"installed"`
	Source           struct {
		Path string `json:"path"`
	} `json:"source"`
}

// tool is one tool@version the config file asks for.
type tool struct{ name, version string }

func (t tool) String() string { return t.name + "@" + t.version }

// errManual is a gap a person must close before mise can be read.
type errManual struct{ resource, msg string }

func (e errManual) Error() string { return e.msg }

// installed is a declared tool's state: whether mise has it, and the version
// the request resolves to.
type installed struct {
	ok      bool
	version string
}

// declared lists the tools t's file asks for, and whether each is installed.
// mise also reports tools from global and parent configs, so only entries
// whose source is this file count.
func (p Provider) declared(ctx context.Context, t config.Target) (map[tool]installed, error) {
	if !p.r.Has("mise") {
		return nil, errManual{"mise", "mise is not on PATH; install mise first"}
	}
	file, err := filepath.EvalSymlinks(t.File)
	if err != nil {
		return nil, fmt.Errorf("read mise config: %w", err)
	}
	out, err := p.r.Output(ctx, "mise", "ls", "--json", "-C", filepath.Dir(t.File))
	if err != nil {
		if strings.Contains(err.Error(), "not trusted") {
			return nil, errManual{"trust", "mise does not trust " + t.File + "; review it, then run mise trust " + t.File}
		}
		return nil, err
	}
	var all map[string][]version
	if err := json.Unmarshal(out, &all); err != nil {
		return nil, fmt.Errorf("read mise ls output: %w", err)
	}
	tools := map[tool]installed{}
	for name, vs := range all {
		for _, v := range vs {
			if !sameFile(v.Source.Path, file) {
				continue
			}
			want := v.RequestedVersion
			if want == "" {
				want = v.Version
			}
			k := tool{name, want}
			if have := tools[k]; !have.ok {
				tools[k] = installed{ok: v.Installed, version: v.Version}
			}
		}
	}
	return tools, nil
}

func sameFile(a, b string) bool {
	if a == "" {
		return false
	}
	if resolved, err := filepath.EvalSymlinks(a); err == nil {
		a = resolved
	}
	ai, err1 := os.Stat(a)
	bi, err2 := os.Stat(b)
	return err1 == nil && err2 == nil && os.SameFile(ai, bi)
}

// Plan installs each declared tool version that is missing.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	tools, err := p.declared(ctx, t)
	if m := (errManual{}); errors.As(err, &m) {
		return []plan.Action{{Op: plan.OpManual, Target: t.Name, Resource: m.resource, Detail: m.msg}}, nil
	}
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(t.File)
	var actions []plan.Action
	for _, k := range sorted(tools) {
		if tools[k].ok {
			continue
		}
		actions = append(actions, plan.Action{
			Op: plan.OpCreate, Target: t.Name, Resource: k.String(), Detail: "install with mise",
			Do: func(ctx context.Context) error { return p.r.Run(ctx, "mise", "install", "-C", dir, k.String()) },
		})
	}
	return actions, nil
}

// Measure counts the declared tool versions that are installed.
func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	tools, err := p.declared(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(tools)}
	for _, have := range tools {
		if have.ok {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d tools installed", live.InPlace, live.Declared)
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

func sorted(m map[tool]installed) []tool {
	keys := make([]tool, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].String() < keys[j].String() })
	return keys
}

// Items lists every declared tool version, with the version it resolves to.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	tools, err := p.declared(ctx, t)
	if err != nil {
		return nil, err
	}
	items := make([]provider.Item, 0, len(tools))
	for _, k := range sorted(tools) {
		item := provider.Item{Name: k.name, Kind: "runtime", State: provider.Missing,
			Version: tools[k].version, Desc: "requested " + k.version}
		if tools[k].ok {
			item.State = provider.InPlace
		}
		items = append(items, item)
	}
	return items, nil
}

func (Provider) Programs(config.Target) []string { return []string{"mise"} }
