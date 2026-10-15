// Package keyboard remaps keys on Linux with keyd: it installs the declared
// keyd config as /etc/keyd/default.conf and keeps the keyd service enabled
// and running. Both are system-wide, so the writes go through sudo.
package keyboard

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// Conf is where keyd reads the config that applies to every keyboard.
const Conf = "/etc/keyd/default.conf"

// binaries are keyd's names: Debian and Ubuntu ship it as keyd.rvaiya, since
// another package already has the name keyd.
var binaries = []string{"keyd", "keyd.rvaiya"}

type Provider struct {
	r sh.Runner
	// conf is Conf, or a file a test owns.
	conf string
}

func New(r sh.Runner) Provider { return Provider{r: r, conf: Conf} }

// state is what the machine says about the config file and the service.
type state struct {
	// keyd is the program's name here, empty when it is not installed.
	keyd string
	// conf is in place, missing or differs.
	conf string
	// service is in place when keyd is enabled and active; detail says what
	// systemd reports otherwise.
	service, detail string
}

func (p Provider) binary() string {
	for _, b := range binaries {
		if p.r.Has(b) {
			return b
		}
	}
	return ""
}

func (p Provider) read(ctx context.Context, t config.Target) (state, error) {
	want, err := os.ReadFile(t.File)
	if err != nil {
		return state{}, fmt.Errorf("keyd config: %w", err)
	}
	s := state{keyd: p.binary(), conf: provider.Missing, service: provider.Missing, detail: "not found"}
	switch have, err := os.ReadFile(p.conf); {
	case err == nil && bytes.Equal(have, want):
		s.conf = provider.InPlace
	case err == nil:
		s.conf = provider.Differs
	case !errors.Is(err, fs.ErrNotExist):
		return state{}, fmt.Errorf("keyd config: %w", err)
	}
	if out, err := p.r.Output(ctx, "systemctl", "show", "keyd", "--property=ActiveState,UnitFileState"); err == nil {
		props := map[string]string{}
		for line := range strings.Lines(string(out)) {
			if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
				props[k] = v
			}
		}
		if props["UnitFileState"] != "" {
			s.detail = props["UnitFileState"] + ", " + props["ActiveState"]
			if strings.HasPrefix(props["UnitFileState"], "enabled") && props["ActiveState"] == "active" {
				s.service = provider.InPlace
			}
		}
	}
	return s, nil
}

// Plan installs the config, then enables and starts keyd. A running keyd
// reloads a changed config; one it starts reads the new file anyway.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	s, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	if s.keyd == "" {
		return []plan.Action{{Op: plan.OpManual, Target: t.Name, Resource: "keyd",
			Detail: "keyd is not installed; add it to your packages (apt install keyd, or the keyd COPR on Fedora), then plan again"}}, nil
	}
	var actions []plan.Action
	if s.conf != provider.InPlace {
		op, detail := plan.OpCreate, "install as "+p.conf
		if s.conf == provider.Differs {
			op, detail = plan.OpUpdate, "replace "+p.conf
		}
		src, dst, keyd, reload := t.File, p.conf, s.keyd, s.service == provider.InPlace
		actions = append(actions, plan.Action{Op: op, Target: t.Name, Resource: "keyd:" + p.conf, Detail: detail + " with sudo",
			Do: func(ctx context.Context) error {
				if err := p.r.Run(ctx, "sudo", "install", "-D", "-m", "644", src, dst); err != nil {
					return err
				}
				if reload {
					return p.r.Run(ctx, "sudo", keyd, "reload")
				}
				return nil
			}})
	}
	if s.service != provider.InPlace {
		actions = append(actions, plan.Action{Op: plan.OpCreate, Target: t.Name, Resource: "service:keyd",
			Detail: "enable and start with sudo systemctl (now " + s.detail + ")",
			Do:     func(ctx context.Context) error { return p.r.Run(ctx, "sudo", "systemctl", "enable", "--now", "keyd") }})
	}
	return actions, nil
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	s, err := p.read(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: 2}
	for _, st := range []string{s.conf, s.service} {
		if st == provider.InPlace {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of 2 keyd parts in place", live.InPlace)
	if s.keyd == "" {
		live.Summary = "keyd is not installed"
	}
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	s, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	return []provider.Item{
		{Name: p.conf, Kind: "keyd", State: s.conf},
		{Name: "keyd", Kind: "service", State: s.service, Desc: s.detail},
	}, nil
}

func (p Provider) Programs(config.Target) []string {
	keyd := p.binary()
	if keyd == "" {
		keyd = "keyd"
	}
	return []string{keyd, "systemctl", "sudo"}
}
