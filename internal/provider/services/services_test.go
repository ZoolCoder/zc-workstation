package services

import (
	"context"
	"slices"
	"testing"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

const list = `[{"name":"sketchybar","status":"started"},{"name":"asimov","status":"scheduled"},
{"name":"colima","status":"none"},{"name":"borders","status":"error"}]`

func target() config.Target {
	return config.Target{Name: "services", Provider: "services", OS: []string{"darwin"},
		Services: []string{"sketchybar", "asimov", "colima", "borders", "postgresql"},
		Agents:   []string{"/Users/me/Library/LaunchAgents/local.weekly.plist", "/Users/me/Library/LaunchAgents/local.ssh.plist"}}
}

// machine runs sketchybar and asimov, has colima stopped, borders failed and
// postgresql not installed, and has only the ssh agent loaded.
func machine() *sh.Fake {
	return &sh.Fake{
		Out: map[string]string{
			"brew services list --json":         list,
			"launchctl print gui/501/local.ssh": "state = running\n",
		},
	}
}

func TestPlanStartsWhatIsNotRunning(t *testing.T) {
	r := machine()
	p := Provider{r: r, uid: 501}
	actions, err := p.Plan(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, a.Resource)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if want := []string{"brew:colima", "brew:borders", "brew:postgresql", "agent:local.weekly"}; !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{
		"brew services restart colima", "brew services restart borders", "brew services restart postgresql",
		"launchctl bootstrap gui/501 /Users/me/Library/LaunchAgents/local.weekly.plist",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
}

func TestMeasureAndPrograms(t *testing.T) {
	p := Provider{r: machine(), uid: 501}
	live, err := p.Measure(context.Background(), target())
	if err != nil {
		t.Fatal(err)
	}
	if live.InPlace != 3 || live.Declared != 7 {
		t.Fatalf("live %+v", live)
	}
	if got := p.Programs(config.Target{Agents: []string{"a.plist"}}); !slices.Equal(got, []string{"launchctl"}) {
		t.Fatalf("programs %v", got)
	}
}

func TestPlanNeedsNoBrewForAgentsOnly(t *testing.T) {
	p := Provider{r: &sh.Fake{}, uid: 501}
	tg := target()
	tg.Services = nil
	if _, err := p.Plan(context.Background(), tg); err != nil {
		t.Fatal(err)
	}
}

func TestPlanEnablesSystemdUnits(t *testing.T) {
	r := &sh.Fake{Out: map[string]string{
		"systemctl --user show backup.timer --property=ActiveState,UnitFileState":      "ActiveState=active\nUnitFileState=enabled\n",
		"systemctl --user show syncthing.service --property=ActiveState,UnitFileState": "ActiveState=inactive\nUnitFileState=disabled\n",
		"systemctl --user show gone.service --property=ActiveState,UnitFileState":      "ActiveState=inactive\nUnitFileState=\n",
	}}
	p := Provider{r: r, uid: 1000}
	tg := config.Target{Name: "services", Provider: "services", OS: []string{"linux"},
		Agents: []string{"/home/me/.config/systemd/user/backup.timer", "/home/me/units/syncthing.service", "/home/me/units/gone.service"}}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, a.Resource+": "+a.Detail)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		"unit:syncthing.service: enable and start with systemctl --user (now disabled, inactive)",
		"unit:gone.service: enable and start with systemctl --user (now not found)",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	ran := []string{
		"systemctl --user daemon-reload", "systemctl --user enable --now /home/me/units/syncthing.service",
		"systemctl --user daemon-reload", "systemctl --user enable --now /home/me/units/gone.service",
	}
	if !slices.Equal(r.Ran, ran) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, ran)
	}
	if got := p.Programs(tg); !slices.Equal(got, []string{"systemctl"}) {
		t.Fatalf("programs %v", got)
	}
}

func TestPlanRegistersScheduledTasks(t *testing.T) {
	ps := func(command string) string {
		return sh.Line("powershell", "-NoProfile", "-NonInteractive", "-Command", command)
	}
	enable := ps("Enable-ScheduledTask -TaskName 'it''s sync' -ErrorAction Stop")
	register := ps("Register-ScheduledTask -TaskName 'cleanup' -Xml (Get-Content -Raw -LiteralPath 'C:/cfg/tasks/cleanup.xml') -Force -ErrorAction Stop")
	r := &sh.Fake{Out: map[string]string{
		ps("(Get-ScheduledTask -TaskName 'backup' -ErrorAction Stop).State"):     "Ready\r\n",
		ps("(Get-ScheduledTask -TaskName 'it''s sync' -ErrorAction Stop).State"): "Disabled\r\n",
	}}
	p := Provider{r: r}
	tg := config.Target{Name: "tasks", Provider: "services", OS: []string{"windows"},
		Agents: []string{"C:/cfg/tasks/backup.xml", "C:/cfg/tasks/it's sync.xml", "C:/cfg/tasks/cleanup.xml"}}
	actions, err := p.Plan(context.Background(), tg)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, a := range actions {
		got = append(got, string(a.Op)+" "+a.Resource+": "+a.Detail)
		if err := a.Do(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{
		string(plan.OpUpdate) + " task:it's sync: enable the task in Task Scheduler (now disabled)",
		string(plan.OpCreate) + " task:cleanup: register cleanup.xml with Task Scheduler",
	}
	if !slices.Equal(got, want) {
		t.Fatalf("plan\n got %q\nwant %q", got, want)
	}
	if !slices.Equal(r.Ran, []string{enable, register}) {
		t.Fatalf("ran\n got %q\nwant %q", r.Ran, []string{enable, register})
	}
	if got := p.Programs(tg); !slices.Equal(got, []string{"powershell"}) {
		t.Fatalf("programs %v", got)
	}
}
