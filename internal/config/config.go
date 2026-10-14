// Package config reads the YAML file that declares the desired state. It
// reads that file and nothing else, so `validate` runs offline.
package config

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// Version is the config schema this build reads.
const Version = 1

// Providers lists the provider names a target may use. A new provider adds
// its name here and its package under internal/provider.
var Providers = []string{"localdir", "packages", "dotfiles", "tools", "desktop"}

// Systems are the values of a target's os list, as Go names them.
var Systems = []string{"darwin", "linux", "windows"}

// Managers are the package managers the packages provider drives.
var Managers = []string{"brew", "apt", "dnf", "winget"}

// Config is the whole file.
type Config struct {
	Version int      `yaml:"version"`
	Targets []Target `yaml:"targets"`
	// Dir is the directory the file was read from; relative target paths
	// resolve against it. Empty for standard input, which resolves against
	// the working directory.
	Dir string `yaml:"-"`
}

// Target is one thing to reconcile.
type Target struct {
	Name     string `yaml:"name"`
	Provider string `yaml:"provider"`
	// OS limits the target to these systems; empty means every system.
	OS []string `yaml:"os"`
	// File is the manifest: a Brewfile, a package list, a winget import file
	// or a mise config.
	File string `yaml:"file"`
	// Manager is the package manager for File; empty picks this system's.
	Manager string `yaml:"manager"`
	// Upgrade makes plan upgrade declared packages or runtimes that have a
	// newer version, not only install the missing ones.
	Upgrade bool `yaml:"upgrade"`
	// Source is the chezmoi source directory the dotfiles provider applies.
	Source string `yaml:"source"`
	// Destination is where dotfiles land; empty means the home directory.
	Destination string `yaml:"destination"`
	// Mode is chezmoi's mode: file (copies, the default) or symlink.
	Mode string `yaml:"mode"`
	// Path is the directory the localdir provider manages.
	Path string `yaml:"path"`
	// Prune deletes files in Path that the config does not declare.
	Prune bool `yaml:"prune"`
	// Files maps a path relative to Path to the content it should hold.
	Files map[string]string `yaml:"files"`
	// Wallpaper is the picture the desktop provider sets on every desktop.
	Wallpaper string `yaml:"wallpaper"`
	// Screensaver is the web page the desktop provider has WebViewScreenSaver
	// show.
	Screensaver string `yaml:"screensaver"`
}

// Root is the target's directory, resolved against the config's directory.
func (c Config) Root(t Target) string { return c.resolve(t.Path) }

// Resolve returns t with every path made absolute: ~ is the home directory,
// and a relative path is relative to the config's directory.
func (c Config) Resolve(t Target) Target {
	t.Path, t.File, t.Source = c.resolve(t.Path), c.resolve(t.File), c.resolve(t.Source)
	t.Destination = c.resolve(t.Destination)
	t.Wallpaper, t.Screensaver = c.resolve(t.Wallpaper), c.resolve(t.Screensaver)
	return t
}

func (c Config) resolve(p string) string {
	switch {
	case p == "":
		return ""
	case p == "~" || strings.HasPrefix(p, "~/"):
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[1:])
		}
		return p
	case filepath.IsAbs(p):
		return p
	}
	return filepath.Join(c.Dir, p)
}

// Where is what the target reads: its manifest, chezmoi source or directory.
func (t Target) Where() string {
	switch {
	case t.Source != "":
		return t.Source
	case t.File != "":
		return t.File
	}
	return t.Path
}

// ForOS reports whether t applies on the named system.
func (t Target) ForOS(goos string) bool { return len(t.OS) == 0 || slices.Contains(t.OS, goos) }

// Names lists the target names in file order.
func (c Config) Names() []string {
	names := make([]string, 0, len(c.Targets))
	for _, t := range c.Targets {
		names = append(names, t.Name)
	}
	return names
}

// Find returns the named target.
func (c Config) Find(name string) (Target, bool) {
	for _, t := range c.Targets {
		if t.Name == name {
			return t, true
		}
	}
	return Target{}, false
}

// Load reads path, or standard input when path is "-".
func Load(path string, stdin io.Reader) (Config, error) {
	var (
		data []byte
		err  error
		dir  string
	)
	if path == "-" {
		data, err = io.ReadAll(stdin)
	} else {
		if dir, err = filepath.Abs(filepath.Dir(path)); err == nil {
			data, err = os.ReadFile(path)
		}
	}
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	cfg, err := Parse(data)
	if err != nil {
		return Config{}, fmt.Errorf("%s: %w", path, err)
	}
	cfg.Dir = dir
	return cfg, nil
}

// Parse decodes and validates a config. Unknown keys are refused: a typo
// that is silently ignored is a setting that silently does nothing.
func Parse(data []byte) (Config, error) {
	var cfg Config
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&cfg); err != nil && !errors.Is(err, io.EOF) {
		return Config{}, err
	}
	return cfg, cfg.Validate()
}

var kebab = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)

// Validate reports every problem at once, so one run fixes the file.
func (c Config) Validate() error {
	var errs []error
	if c.Version != Version {
		errs = append(errs, fmt.Errorf("version is %d, this build reads version %d", c.Version, Version))
	}
	seen := map[string]bool{}
	for i, t := range c.Targets {
		where := fmt.Sprintf("targets[%d]", i)
		if t.Name != "" {
			where = "target " + t.Name
		}
		switch {
		case !kebab.MatchString(t.Name):
			errs = append(errs, fmt.Errorf("%s: name %q must be kebab-case", where, t.Name))
		case seen[t.Name]:
			errs = append(errs, fmt.Errorf("%s: declared twice", where))
		}
		seen[t.Name] = true
		if !slices.Contains(Providers, t.Provider) {
			errs = append(errs, fmt.Errorf("%s: provider %q is not one of %s", where, t.Provider, strings.Join(Providers, ", ")))
		} else {
			errs = append(errs, t.validateFields(where)...)
		}
		for _, goos := range t.OS {
			if !slices.Contains(Systems, goos) {
				errs = append(errs, fmt.Errorf("%s: os %q is not one of %s", where, goos, strings.Join(Systems, ", ")))
			}
		}
	}
	return errors.Join(errs...)
}

// validateFields checks the fields each provider needs, and refuses the ones
// it would ignore.
func (t Target) validateFields(where string) []error {
	var errs []error
	need := func(field, value string) {
		if value == "" {
			errs = append(errs, fmt.Errorf("%s: %s is required for provider %s", where, field, t.Provider))
		}
	}
	unused := func(field string, set bool) {
		if set {
			errs = append(errs, fmt.Errorf("%s: %s does nothing for provider %s", where, field, t.Provider))
		}
	}
	switch t.Provider {
	case "localdir":
		need("path", t.Path)
		for name := range t.Files {
			if !filepath.IsLocal(name) {
				errs = append(errs, fmt.Errorf("%s: file %q must stay inside the target path", where, name))
			}
		}
	case "packages":
		need("file", t.File)
		if t.Manager != "" && !slices.Contains(Managers, t.Manager) {
			errs = append(errs, fmt.Errorf("%s: manager %q is not one of %s", where, t.Manager, strings.Join(Managers, ", ")))
		}
	case "dotfiles":
		need("source", t.Source)
		if t.Mode != "" && t.Mode != "file" && t.Mode != "symlink" {
			errs = append(errs, fmt.Errorf("%s: mode %q is not file or symlink", where, t.Mode))
		}
	case "tools":
		need("file", t.File)
	case "desktop":
		if t.Wallpaper == "" && t.Screensaver == "" {
			errs = append(errs, fmt.Errorf("%s: set wallpaper, screensaver or both for provider desktop", where))
		}
		if !slices.Equal(t.OS, []string{"darwin"}) {
			errs = append(errs, fmt.Errorf("%s: provider desktop drives macOS only; set os: [darwin]", where))
		}
	}
	if t.Provider != "localdir" {
		unused("path", t.Path != "")
		unused("files", len(t.Files) > 0)
		unused("prune", t.Prune)
	}
	if t.Provider != "packages" {
		unused("manager", t.Manager != "")
	}
	if t.Provider != "packages" && t.Provider != "tools" {
		unused("upgrade", t.Upgrade)
	}
	if t.Provider != "dotfiles" {
		unused("source", t.Source != "")
		unused("destination", t.Destination != "")
		unused("mode", t.Mode != "")
	}
	if t.Provider == "localdir" || t.Provider == "dotfiles" || t.Provider == "desktop" {
		unused("file", t.File != "")
	}
	if t.Provider != "desktop" {
		unused("wallpaper", t.Wallpaper != "")
		unused("screensaver", t.Screensaver != "")
	}
	return errs
}
