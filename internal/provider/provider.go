// Package provider is the seam between the engine and a live system. A
// provider reads live state and returns the actions that would make it match
// a target; each action's Do closure carries the write.
//
// Add a provider: implement Provider in a package under internal/provider,
// add its name to config.Providers, and register it in engine.Default.
package provider

import (
	"context"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/plan"
)

// Provider reconciles one kind of target. The engine hands it a target whose
// paths are already resolved against the config file's directory.
type Provider interface {
	// Plan compares live state with t and returns what would change. It must
	// not write.
	Plan(ctx context.Context, t config.Target) ([]plan.Action, error)
	// Status is a one-line summary of live state, without diffing.
	Status(ctx context.Context, t config.Target) (string, error)
}

// Live is a target's measured state: how many of the items it declares are
// in place.
type Live struct {
	InPlace, Declared int
	Summary           string
}

// Measurer is a Provider that can count what is in place, so the dashboard
// can draw progress. Status stays the one-line form of the same reading.
type Measurer interface {
	Measure(ctx context.Context, t config.Target) (Live, error)
}

// Requirer is a Provider that runs other programs; the dashboard and doctor
// show whether each is installed.
type Requirer interface {
	Programs(t config.Target) []string
}

// An item's state on this machine.
const (
	InPlace = "in place"
	Missing = "missing"
	Differs = "differs"
	Manual  = "manual"
	// Outdated is in place, with a newer version available.
	Outdated = "outdated"
	// Extra is installed on purpose but declared by no target.
	Extra = "not declared"
)

// Item is one thing a target declares, with what this machine says about it.
// Only Name, Kind and State are always set.
type Item struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	State string `json:"state"`
	// Version is what is installed, when that can be read.
	Version string `json:"version,omitempty"`
	// Latest is the newer version an outdated item can move to.
	Latest string `json:"latest,omitempty"`
	// App is what the item belongs to: the application a cask installs, or
	// the program a dotfile configures.
	App      string `json:"app,omitempty"`
	Desc     string `json:"desc,omitempty"`
	Homepage string `json:"homepage,omitempty"`
}

// Lister is a Provider that can list what a target declares, item by item,
// for the inventory.
type Lister interface {
	Items(ctx context.Context, t config.Target) ([]Item, error)
}

// Capturer is a Provider that can write its manifest from what the machine
// has, so a config can start from a machine that is already set up.
type Capturer interface {
	Capture(ctx context.Context, t config.Target) ([]byte, error)
}
