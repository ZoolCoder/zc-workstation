package packages

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"sync"

	"github.com/zoolcoder/zc-workstation/internal/manifest"
	"github.com/zoolcoder/zc-workstation/internal/sh"
)

var managers = map[string]manager{
	"brew": {
		program:   "brew",
		parse:     parseBrewfile,
		installed: brewInstalled,
		details:   brewDetails,
		chosen:    brewChosen,
		outdated:  brewOutdated,
		upgrade:   brewUpgrade,
		key: func(l string) (string, bool) {
			m := brewLine.FindStringSubmatch(l)
			if m == nil {
				return "", false
			}
			return m[1] + ":" + m[2], true
		},
		entry: func(kind, name string) (string, string, error) {
			switch kind {
			case "":
				kind = "brew"
			case "brew", "cask", "tap":
			default:
				return "", "", fmt.Errorf("a Brewfile entry is brew, cask or tap, not %q; add App Store apps by hand, with their id", kind)
			}
			return kind, kind + ` "` + name + `"`, nil
		},
		install: func(r sh.Runner, i item) func(context.Context) error {
			switch i.Kind {
			case "tap":
				// Homebrew loads a third-party tap's formulae only once it is trusted.
				return func(ctx context.Context) error {
					if err := r.Run(ctx, "brew", "tap", i.Name); err != nil {
						return err
					}
					return r.Run(ctx, "brew", "trust", i.Name)
				}
			case "cask":
				return run(r, "brew", "install", "--cask", i.Name)
			case "mas":
				return run(r, "mas", "install", i.ID)
			}
			return run(r, "brew", "install", i.Name)
		},
	},
	"apt": {
		program: "apt-get",
		parse:   listParser("apt"),
		key:     listKey("apt"),
		entry:   listEntry("apt"),
		installed: func(ctx context.Context, r sh.Runner, _ []item) (map[string]set, map[string]string, error) {
			out, err := r.Output(ctx, "dpkg-query", "-W", "-f", "${db:Status-Abbrev}\t${Package}\n")
			if err != nil {
				return nil, nil, err
			}
			have := set{}
			for _, l := range lines(out) {
				status, name, ok := strings.Cut(l, "\t")
				if ok && strings.HasPrefix(status, "ii") {
					have[strings.ToLower(name)] = true
				}
			}
			return map[string]set{"apt": have}, nil, nil
		},
		install: func(r sh.Runner, i item) func(context.Context) error {
			return run(r, "sudo", "apt-get", "install", "-y", i.Name)
		},
		details:  tabDetails("apt", "dpkg-query", "-W", "-f", "${Package}\t${Version}\t${binary:Summary}\t${Homepage}\n"),
		chosen:   listChosen("apt", "apt-mark", "showmanual"),
		outdated: aptOutdated,
		upgrade: func(r sh.Runner, i item) func(context.Context) error {
			return run(r, "sudo", "apt-get", "install", "--only-upgrade", "-y", i.Name)
		},
	},
	"dnf": {
		program: "dnf",
		parse:   listParser("dnf"),
		key:     listKey("dnf"),
		entry:   listEntry("dnf"),
		installed: func(ctx context.Context, r sh.Runner, _ []item) (map[string]set, map[string]string, error) {
			out, err := r.Output(ctx, "rpm", "-qa", "--qf", "%{NAME}\n")
			if err != nil {
				return nil, nil, err
			}
			return map[string]set{"dnf": newSet(lines(out)...)}, nil, nil
		},
		install: func(r sh.Runner, i item) func(context.Context) error {
			return run(r, "sudo", "dnf", "install", "-y", i.Name)
		},
		details:  tabDetails("dnf", "rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}\t%{SUMMARY}\t%{URL}\n"),
		chosen:   listChosen("dnf", "dnf", "repoquery", "--userinstalled", "--qf", "%{name}\n"),
		outdated: dnfOutdated,
		upgrade: func(r sh.Runner, i item) func(context.Context) error {
			return run(r, "sudo", "dnf", "upgrade", "-y", i.Name)
		},
	},
	"winget": {
		program:   "winget",
		parse:     parseWinget,
		installed: wingetInstalled,
		install: func(r sh.Runner, i item) func(context.Context) error {
			return run(r, "winget", "install", "--id", i.Name, "--exact", "--silent",
				"--accept-package-agreements", "--accept-source-agreements")
		},
	},
}

func run(r sh.Runner, name string, args ...string) func(context.Context) error {
	return func(ctx context.Context) error { return r.Run(ctx, name, args...) }
}

func readFile(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read manifest: %w", err)
	}
	return data, nil
}

// brewLine is one Brewfile entry: a kind, a quoted name, and options. Only
// the mas id option matters here.
var (
	brewLine = regexp.MustCompile(`^(\w+)\s+"([^"]+)"(.*)$`)
	masID    = regexp.MustCompile(`id:\s*(\d+)`)
)

// parseBrewfile reads the tap, brew, cask and mas entries of a Brewfile. Any
// other entry (vscode, go, cargo, whalebrew) is returned as unsupported.
func parseBrewfile(data []byte) ([]item, []string, error) {
	var taps, rest []item
	var unsupported []string
	sc := bufio.NewScanner(bytes.NewReader(data))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := brewLine.FindStringSubmatch(line)
		if m == nil {
			return nil, nil, fmt.Errorf("line %d: cannot read %q", n, line)
		}
		i := item{Kind: m[1], Name: m[2]}
		switch i.Kind {
		case "tap":
			taps = append(taps, i)
		case "brew", "cask":
			rest = append(rest, i)
		case "mas":
			id := masID.FindStringSubmatch(m[3])
			if id == nil {
				return nil, nil, fmt.Errorf("line %d: mas %q has no id", n, i.Name)
			}
			i.ID = id[1]
			rest = append(rest, i)
		default:
			unsupported = append(unsupported, i.resource())
		}
	}
	// Taps first, so apply adds a tap before installing from it.
	return append(taps, rest...), unsupported, sc.Err()
}

func brewInstalled(ctx context.Context, r sh.Runner, items []item) (map[string]set, map[string]string, error) {
	have := map[string]set{}
	var (
		mu   sync.Mutex
		errs []error
		wg   sync.WaitGroup
	)
	// Without --full-name brew answers from its shell fast path, not Ruby;
	// set.has matches a tapped package by its short name.
	for kind, args := range map[string][]string{
		"brew": {"list", "--formula", "-1"},
		"cask": {"list", "--cask", "-1"},
		"tap":  {"tap"},
	} {
		wg.Go(func() {
			out, err := r.Output(ctx, "brew", args...)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs = append(errs, err)
				return
			}
			have[kind] = newSet(lines(out)...)
		})
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		return nil, nil, err
	}
	unreadable := map[string]string{}
	if wantsKind(items, "mas") {
		if !r.Has("mas") {
			unreadable["mas"] = "mas is not on PATH; install it (brew install mas) to manage App Store apps"
		} else {
			out, err := r.Output(ctx, "mas", "list")
			if err != nil {
				return nil, nil, err
			}
			ids := set{}
			for _, l := range lines(out) {
				if f := strings.Fields(l); len(f) > 0 {
					ids[f[0]] = true
				}
			}
			have["mas"] = ids
		}
	}
	return have, unreadable, nil
}

// listParser reads a plain package list: one name per line, # comments.
func listParser(kind string) func([]byte) ([]item, []string, error) {
	return func(data []byte) ([]item, []string, error) {
		var items []item
		for l := range strings.SplitSeq(string(data), "\n") {
			if before, _, _ := strings.Cut(l, "#"); strings.TrimSpace(before) != "" {
				items = append(items, item{Kind: kind, Name: strings.TrimSpace(before)})
			}
		}
		return items, nil, nil
	}
}

func listKey(kind string) manifest.Key {
	return func(l string) (string, bool) { return kind + ":" + l, true }
}

func listEntry(kind string) func(string, string) (string, string, error) {
	return func(k, name string) (string, string, error) {
		if k != "" && k != kind {
			return "", "", fmt.Errorf("this manifest lists %s packages, not %q", kind, k)
		}
		return kind, name, nil
	}
}

// parseWinget reads the file `winget export` writes and `winget import` reads.
func parseWinget(data []byte) ([]item, []string, error) {
	var doc struct {
		Sources []struct {
			Packages []struct {
				PackageIdentifier string
			}
		}
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, nil, err
	}
	var items []item
	for _, s := range doc.Sources {
		for _, p := range s.Packages {
			items = append(items, item{Kind: "winget", Name: p.PackageIdentifier})
		}
	}
	return items, nil, nil
}

// wingetInstalled asks winget about each package by exact id: its list output
// is a table meant for people, but its exit code is reliable.
func wingetInstalled(ctx context.Context, r sh.Runner, items []item) (map[string]set, map[string]string, error) {
	have := set{}
	for _, i := range items {
		_, err := r.Output(ctx, "winget", "list", "--id", i.Name, "--exact",
			"--accept-source-agreements", "--disable-interactivity")
		if err == nil {
			have[strings.ToLower(i.Name)] = true
		}
	}
	return map[string]set{"winget": have}, nil, nil
}

func wantsKind(items []item, kind string) bool {
	return slices.ContainsFunc(items, func(i item) bool { return i.Kind == kind })
}
