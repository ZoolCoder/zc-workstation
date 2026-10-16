// Package services keeps background services running: Homebrew services,
// launchd agents from plists on a Mac, systemd user units and timers on
// Linux, and Task Scheduler tasks on Windows. It starts what is stopped and
// never stops anything.
package services

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/provider"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

// running are the brew services states that count as in place: a service
// that runs on a schedule, such as asimov, is scheduled between runs.
var running = []string{"started", "scheduled"}

type Provider struct {
	r   sh.Runner
	uid int
}

func New(r sh.Runner) Provider { return Provider{r: r, uid: os.Getuid()} }

// service is one declared service or agent with what the machine says.
type service struct {
	kind, name string
	// file is an agent's plist or unit file.
	file   string
	state  string
	detail string
}

// Label is the agent's launchd label, which by convention is its file name.
func Label(plist string) string { return strings.TrimSuffix(filepath.Base(plist), ".plist") }

// IsUnit reports whether an agent is a systemd unit rather than a plist.
func IsUnit(file string) bool {
	ext := filepath.Ext(file)
	return ext == ".service" || ext == ".timer"
}

// IsTask reports whether an agent is a Task Scheduler task file.
func IsTask(file string) bool { return filepath.Ext(file) == ".xml" }

// TaskName is the name a task file registers, its file name without .xml.
func TaskName(file string) string { return strings.TrimSuffix(filepath.Base(file), ".xml") }

func (p Provider) domain() string { return fmt.Sprintf("gui/%d", p.uid) }

// read asks launchctl about the agents while brew lists its services, the
// slow part.
func (p Provider) read(ctx context.Context, t config.Target) ([]service, error) {
	agents := make([]service, len(t.Agents))
	var wg sync.WaitGroup
	for i, plist := range t.Agents {
		wg.Go(func() {
			if IsUnit(plist) {
				agents[i] = p.unit(ctx, plist)
				return
			}
			if IsTask(plist) {
				agents[i] = p.task(ctx, plist)
				return
			}
			s := service{kind: "agent", name: Label(plist), file: plist, state: provider.Missing, detail: "not loaded"}
			if _, err := p.r.Output(ctx, "launchctl", "print", p.domain()+"/"+s.name); err == nil {
				s.state, s.detail = provider.InPlace, "loaded"
			}
			agents[i] = s
		})
	}
	defer wg.Wait()
	var out []service
	if len(t.Services) > 0 {
		status, err := p.brewStatus(ctx)
		if err != nil {
			return nil, err
		}
		for _, name := range t.Services {
			s := service{kind: "brew", name: name, state: provider.Missing, detail: "not installed"}
			if st, ok := status[name]; ok {
				s.detail = st
				if slices.Contains(running, st) {
					s.state = provider.InPlace
				}
			}
			out = append(out, s)
		}
	}
	wg.Wait()
	return append(out, agents...), nil
}

// unit reads a systemd user unit: in place when enabled and active, which
// for a timer means waiting for its next run.
func (p Provider) unit(ctx context.Context, file string) service {
	s := service{kind: "unit", name: filepath.Base(file), file: file, state: provider.Missing, detail: "not found"}
	out, err := p.r.Output(ctx, "systemctl", "--user", "show", s.name, "--property=ActiveState,UnitFileState")
	if err != nil {
		return s
	}
	props := map[string]string{}
	for line := range strings.Lines(string(out)) {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
			props[k] = v
		}
	}
	if props["UnitFileState"] == "" {
		return s
	}
	s.detail = props["UnitFileState"] + ", " + props["ActiveState"]
	if strings.HasPrefix(props["UnitFileState"], "enabled") && props["ActiveState"] == "active" {
		s.state = provider.InPlace
	}
	return s
}

// task reads a Task Scheduler task through PowerShell, whose state names do
// not change with the system language as schtasks output does. A task is in
// place unless it is disabled.
func (p Provider) task(ctx context.Context, file string) service {
	s := service{kind: "task", name: TaskName(file), file: file, state: provider.Missing, detail: "not registered"}
	out, err := p.r.Output(ctx, "powershell", psArgs("(Get-ScheduledTask -TaskName "+psQuote(s.name)+" -ErrorAction Stop).State")...)
	if err != nil {
		return s
	}
	s.detail = strings.ToLower(strings.TrimSpace(string(out)))
	if s.detail == "disabled" {
		s.state = provider.Differs
	} else {
		s.state = provider.InPlace
	}
	return s
}

// psArgs are the arguments that run one PowerShell command, without the
// user's profile or prompts.
func psArgs(command string) []string {
	return []string{"-NoProfile", "-NonInteractive", "-Command", command}
}

// psQuote is s as a single-quoted PowerShell string.
func psQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// brewStatus maps each Homebrew service to its state, such as started.
func (p Provider) brewStatus(ctx context.Context) (map[string]string, error) {
	out, err := p.r.Output(ctx, "brew", "services", "list", "--json")
	if err != nil {
		return nil, fmt.Errorf("brew services list: %w", err)
	}
	var list []struct{ Name, Status string }
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, fmt.Errorf("brew services list: %w", err)
	}
	status := make(map[string]string, len(list))
	for _, s := range list {
		status[s.Name] = s.Status
	}
	return status, nil
}

// Plan starts each service that is not running and loads each agent that is
// not loaded or enabled. An agent's file may not exist yet: a dotfiles target
// earlier in the same apply writes it.
func (p Provider) Plan(ctx context.Context, t config.Target) ([]plan.Action, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	var actions []plan.Action
	for _, s := range services {
		if s.state == provider.InPlace {
			continue
		}
		a := plan.Action{Op: plan.OpCreate, Target: t.Name, Resource: s.kind + ":" + s.name}
		switch s.kind {
		case "brew":
			a.Detail = "start with brew services, and at every login (now " + s.detail + ")"
			// restart also recovers a service that started and then failed.
			a.Do = func(ctx context.Context) error { return p.r.Run(ctx, "brew", "services", "restart", s.name) }
		case "task":
			if s.state == provider.Differs {
				a.Op, a.Detail = plan.OpUpdate, "enable the task in Task Scheduler (now disabled)"
				a.Do = func(ctx context.Context) error {
					return p.r.Run(ctx, "powershell", psArgs("Enable-ScheduledTask -TaskName "+psQuote(s.name)+" -ErrorAction Stop")...)
				}
				break
			}
			// Get-Content reads the file in whatever encoding it has; schtasks
			// /XML refuses some, such as UTF-8 without a byte order mark.
			a.Detail = "register " + filepath.Base(s.file) + " with Task Scheduler"
			a.Do = func(ctx context.Context) error {
				return p.r.Run(ctx, "powershell", psArgs("Register-ScheduledTask -TaskName "+psQuote(s.name)+
					" -Xml (Get-Content -Raw -LiteralPath "+psQuote(s.file)+") -Force -ErrorAction Stop")...)
			}
		case "unit":
			a.Detail = "enable and start with systemctl --user (now " + s.detail + ")"
			// enable takes the file's path, so a unit outside systemd's
			// folders is linked in; daemon-reload picks up a changed file.
			a.Do = func(ctx context.Context) error {
				if err := p.r.Run(ctx, "systemctl", "--user", "daemon-reload"); err != nil {
					return err
				}
				return p.r.Run(ctx, "systemctl", "--user", "enable", "--now", s.file)
			}
		default:
			a.Detail = "load " + filepath.Base(s.file) + " into launchd"
			a.Do = func(ctx context.Context) error { return p.r.Run(ctx, "launchctl", "bootstrap", p.domain(), s.file) }
		}
		actions = append(actions, a)
	}
	return actions, nil
}

func (p Provider) Measure(ctx context.Context, t config.Target) (provider.Live, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return provider.Live{}, err
	}
	live := provider.Live{Declared: len(services)}
	for _, s := range services {
		if s.state == provider.InPlace {
			live.InPlace++
		}
	}
	live.Summary = fmt.Sprintf("%d of %d services running", live.InPlace, live.Declared)
	return live, nil
}

func (p Provider) Status(ctx context.Context, t config.Target) (string, error) {
	live, err := p.Measure(ctx, t)
	return live.Summary, err
}

// Items is each service, then each agent, as declared.
func (p Provider) Items(ctx context.Context, t config.Target) ([]provider.Item, error) {
	services, err := p.read(ctx, t)
	if err != nil {
		return nil, err
	}
	items := make([]provider.Item, 0, len(services))
	for _, s := range services {
		items = append(items, provider.Item{Name: s.name, Kind: s.kind, State: s.state, Desc: s.detail})
	}
	return items, nil
}

func (Provider) Programs(t config.Target) []string {
	var progs []string
	if len(t.Services) > 0 {
		progs = append(progs, "brew")
	}
	if slices.ContainsFunc(t.Agents, IsUnit) {
		progs = append(progs, "systemctl")
	}
	if slices.ContainsFunc(t.Agents, IsTask) {
		progs = append(progs, "powershell")
	}
	if slices.ContainsFunc(t.Agents, func(a string) bool { return !IsUnit(a) && !IsTask(a) }) {
		progs = append(progs, "launchctl")
	}
	return progs
}
