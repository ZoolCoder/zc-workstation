package packages

import (
	"context"
	"encoding/json"
	"regexp"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// detail is what a package manager says about one installed package.
type detail struct {
	Version, App, Desc, Homepage string
}

// details maps "kind:name" (lower case) to what the manager knows about it.
type details map[string]detail

func (d details) find(i item) detail {
	key := strings.ToLower(i.Name)
	if i.ID != "" {
		key = i.ID
	}
	if v, ok := d[i.Kind+":"+key]; ok {
		return v
	}
	return d[i.Kind+":"+key[strings.LastIndex(key, "/")+1:]]
}

// Items lists every declared package with its state and, when the manager
// can say, its version and description.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	s, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	// Details are extra: a manager that cannot give them still lists items.
	info := details{}
	if read := managers[s.manager].details; read != nil {
		if d, err := read(ctx, p.r); err == nil {
			info = d
		}
	}
	state := map[string]string{}
	for _, i := range s.missing {
		state[i.resource()] = provider.Missing
	}
	for _, a := range s.manual {
		state[a.Resource] = provider.Manual
	}
	items := make([]provider.Item, 0, len(s.items)+len(s.unsupported))
	for _, i := range s.items {
		st, ok := state[i.resource()]
		if !ok {
			st = provider.InPlace
		}
		d := info.find(i)
		items = append(items, provider.Item{Name: i.Name, Kind: i.Kind, State: st,
			Version: d.Version, App: d.App, Desc: d.Desc, Homepage: d.Homepage})
	}
	for _, u := range s.unsupported {
		kind, name, _ := strings.Cut(u, ":")
		items = append(items, provider.Item{Name: name, Kind: kind, State: provider.Manual,
			Desc: "zc-workstation does not install this kind of entry"})
	}
	return items, nil
}

// brewDetails reads every installed formula and cask in one call, then the
// App Store apps from mas.
func brewDetails(ctx context.Context, r sh.Runner) (details, error) {
	out, err := r.Output(ctx, "brew", "info", "--json=v2", "--installed")
	if err != nil {
		return nil, err
	}
	var doc struct {
		Formulae []struct {
			Name, Desc, Homepage string
			FullName             string `json:"full_name"`
			Installed            []struct{ Version string }
		}
		Casks []struct {
			Token, Desc, Homepage string
			FullToken             string `json:"full_token"`
			Name                  []string
			Installed             string
		}
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, err
	}
	d := details{}
	for _, f := range doc.Formulae {
		v := detail{Desc: f.Desc, Homepage: f.Homepage}
		if n := len(f.Installed); n > 0 {
			v.Version = f.Installed[n-1].Version
		}
		d["brew:"+strings.ToLower(f.Name)] = v
		d["brew:"+strings.ToLower(f.FullName)] = v
	}
	for _, c := range doc.Casks {
		v := detail{Version: c.Installed, Desc: c.Desc, Homepage: c.Homepage}
		if len(c.Name) > 0 {
			v.App = c.Name[0]
		}
		d["cask:"+strings.ToLower(c.Token)] = v
		d["cask:"+strings.ToLower(c.FullToken)] = v
	}
	if r.Has("mas") {
		if out, err := r.Output(ctx, "mas", "list"); err == nil {
			for _, l := range lines(out) {
				if m := masLine.FindStringSubmatch(l); m != nil {
					d["mas:"+m[1]] = detail{App: m[2], Version: m[3]}
				}
			}
		}
	}
	return d, nil
}

// masLine is one line of `mas list`: id, name, (version).
var masLine = regexp.MustCompile(`^\s*(\d+)\s+(.*?)\s+\(([^)]*)\)\s*$`)

// tabDetails reads "name\tversion\tsummary\thomepage" lines into kind's
// details, as dpkg-query and rpm print them.
func tabDetails(kind, name string, args ...string) func(context.Context, sh.Runner) (details, error) {
	return func(ctx context.Context, r sh.Runner) (details, error) {
		out, err := r.Output(ctx, name, args...)
		if err != nil {
			return nil, err
		}
		d := details{}
		for _, l := range lines(out) {
			f := strings.Split(l, "\t")
			if len(f) < 4 || f[0] == "" {
				continue
			}
			d[kind+":"+strings.ToLower(f[0])] = detail{Version: f[1], Desc: f[2], Homepage: f[3]}
		}
		return d, nil
	}
}
