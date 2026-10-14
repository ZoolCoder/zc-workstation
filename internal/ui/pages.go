package ui

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/zoolcoder/toolshell"
	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/engine"
	"github.com/zoolcoder/zc-workstation/internal/plan"
)

type targetRow struct {
	config.Target
	Status engine.TargetStatus
	Last   *run
}

// Missing is how many declared items are not in place yet.
func (r targetRow) Missing() int { return r.Status.Declared - r.Status.InPlace }

type program struct {
	Name  string
	Found bool
}

type dashboardPage struct {
	chrome
	Rows      []targetRow
	ConfigErr error
	System    string
	Bin       string
	Programs  []program
	// ForHere counts the targets for this system; the rest are skipped.
	ForHere, InSync, Errors, Skipped int
	InPlace, Missing, Declared       int
	ProgramsMissing                  int
}

// Coverage is the share of declared items in place, in whole percent.
func (p dashboardPage) Coverage() int {
	if p.Declared == 0 {
		return 100
	}
	return p.InPlace * 100 / p.Declared
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	p := dashboardPage{chrome: s.chrome(r, "dashboard"), System: system(), Bin: s.deps.Name}
	cfg, err := s.config()
	if err == nil {
		var eng *engine.Engine
		if eng, err = engine.New(cfg, s.deps.Providers, nil); err == nil {
			c, cancel := ctx(r)
			defer cancel()
			s.fill(&p, cfg, eng.Status(c), eng.Programs())
		}
	}
	p.ConfigErr = err
	s.render(w, "dashboard.html", p)
}

func (s *Server) fill(p *dashboardPage, cfg config.Config, statuses []engine.TargetStatus, programs []string) {
	for i, t := range cfg.Targets {
		row := targetRow{Target: t, Status: statuses[i]}
		if last, ok := s.lastRun(t.Name); ok {
			row.Last = &last
		}
		p.Rows = append(p.Rows, row)
		switch st := row.Status; {
		case st.Skipped:
			p.Skipped++
			continue
		case st.Error != "":
			p.Errors++
		case st.InSync():
			p.InSync++
		}
		p.ForHere++
		p.InPlace += row.Status.InPlace
		p.Declared += row.Status.Declared
	}
	p.Missing = p.Declared - p.InPlace
	for _, name := range programs {
		found := s.deps.Has(name)
		if !found {
			p.ProgramsMissing++
		}
		p.Programs = append(p.Programs, program{Name: name, Found: found})
	}
}

func system() string {
	host, _ := os.Hostname()
	return strings.TrimSpace(fmt.Sprintf("%s %s/%s", host, runtime.GOOS, runtime.GOARCH))
}

type counts struct{ Create, Update, Delete, Manual int }

type targetPage struct {
	chrome
	config.Target
	Live    engine.TargetStatus
	Items   []itemRow
	HasRun  bool
	Run     run
	Counts  counts
	Deletes bool
	Command string
}

func (s *Server) target(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	cfg, err := s.config()
	if err != nil {
		s.fail(w, r, http.StatusInternalServerError, "The config could not be read", err)
		return
	}
	t, ok := cfg.Find(name)
	if !ok {
		s.notFound(w, r)
		return
	}
	p := targetPage{chrome: s.chrome(r, "dashboard"), Target: t,
		Command: fmt.Sprintf("%s apply -config %s -target %s", s.deps.Name, s.deps.ConfigPath, name)}
	p.Title = name
	if eng, err := engine.New(cfg, s.deps.Providers, []string{name}); err == nil {
		c, cancel := ctx(r)
		p.Live = eng.Status(c)[0]
		for _, i := range eng.Items(c)[0].Items {
			p.Items = append(p.Items, itemRow{Item: i, Target: name})
		}
		cancel()
	}
	if last, ok := s.lastRun(name); ok {
		p.HasRun, p.Run = true, last
		p.Deletes = last.Plan.Destructive()
		for _, a := range last.Plan.Actions {
			switch a.Op {
			case plan.OpCreate:
				p.Counts.Create++
			case plan.OpUpdate:
				p.Counts.Update++
			case plan.OpDelete:
				p.Counts.Delete++
			case plan.OpManual:
				p.Counts.Manual++
			}
		}
	}
	s.render(w, "target.html", p)
}

func (s *Server) plan(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	back := "/targets/" + name
	eng, err := s.engine(name)
	if err != nil {
		toolshell.Back(w, r, back, "", err)
		return
	}
	c, cancel := ctx(r)
	defer cancel()
	p, err := eng.Plan(c)
	rn := run{At: s.deps.Now(), Plan: p}
	if err != nil {
		rn.Err = err.Error()
	}
	s.setRun(name, rn)
	s.record("plan", name, fmt.Sprintf("%d change(s)", len(p.Executable())), err)
	toolshell.Back(w, r, back, "planned", err)
}

var errDeletes = errors.New("this plan deletes things; apply it in a terminal")

// apply needs the target's name typed back, re-plans, and refuses unless the
// fresh plan is the one the page showed: what runs is what was reviewed.
func (s *Server) apply(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	back := "/targets/" + name
	if strings.TrimSpace(r.FormValue("confirm")) != name {
		toolshell.Back(w, r, back, "", fmt.Errorf("type %s to confirm", name))
		return
	}
	last, ok := s.lastRun(name)
	if !ok || last.Err != "" {
		toolshell.Back(w, r, back, "", errors.New("plan first, then apply what you reviewed"))
		return
	}
	eng, err := s.engine(name)
	if err != nil {
		toolshell.Back(w, r, back, "", err)
		return
	}
	c, cancel := ctx(r)
	defer cancel()
	fresh, err := eng.Plan(c)
	if err == nil {
		err = last.Plan.Snapshot(nil).Matches(fresh)
	}
	if err == nil && fresh.Destructive() {
		err = errDeletes
	}
	if err != nil {
		s.record("apply", name, "", err)
		toolshell.Back(w, r, back, "", err)
		return
	}
	var out bytes.Buffer
	err = eng.Apply(c, fresh, &out)
	after, planErr := eng.Plan(c)
	rn := run{At: s.deps.Now(), Plan: after, Applied: true, Output: out.String()}
	if err = errors.Join(err, planErr); err != nil {
		rn.Err = err.Error()
	}
	s.setRun(name, rn)
	s.record("apply", name, fmt.Sprintf("%d change(s) applied", len(fresh.Executable())), err)
	toolshell.Back(w, r, back, "applied", err)
}

type activityPage struct {
	chrome
	Rows   []activityRow
	Limit  int
	LogErr error
}

type activityRow struct {
	At                   time.Time
	Kind, Target, Detail string
	OK                   bool
}

func (s *Server) activity(w http.ResponseWriter, r *http.Request) {
	p := activityPage{chrome: s.chrome(r, "activity"), Limit: activityLimit}
	if s.deps.Activity != nil {
		entries, err := s.deps.Activity.Recent(activityLimit)
		p.LogErr = err
		for _, e := range entries {
			p.Rows = append(p.Rows, activityRow{At: e.At, Kind: e.Kind, Target: e.Target, Detail: e.Detail, OK: e.OK})
		}
	}
	s.render(w, "activity.html", p)
}

type settingsPage struct {
	chrome
	Name, ConfigPath, ActivityPath string
	Providers                      []string
}

func (s *Server) settings(w http.ResponseWriter, r *http.Request) {
	p := settingsPage{chrome: s.chrome(r, "settings"), Name: s.deps.Name, ConfigPath: s.deps.ConfigPath, Providers: config.Providers}
	if s.deps.Activity != nil {
		p.ActivityPath = s.deps.Activity.Path
	}
	s.render(w, "settings.html", p)
}
