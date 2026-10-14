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
var Providers = []string{"localdir"}

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
	// Path is the directory the localdir provider manages.
	Path string `yaml:"path"`
	// Prune deletes files in Path that the config does not declare.
	Prune bool `yaml:"prune"`
	// Files maps a path relative to Path to the content it should hold.
	Files map[string]string `yaml:"files"`
}

// Root is the target's directory, resolved against the config's directory.
func (c Config) Root(t Target) string {
	if filepath.IsAbs(t.Path) {
		return t.Path
	}
	return filepath.Join(c.Dir, t.Path)
}

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
		data, err = os.ReadFile(path)
		dir = filepath.Dir(path)
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
		}
		if t.Path == "" {
			errs = append(errs, fmt.Errorf("%s: path is required", where))
		}
		for name := range t.Files {
			if !filepath.IsLocal(name) {
				errs = append(errs, fmt.Errorf("%s: file %q must stay inside the target path", where, name))
			}
		}
	}
	return errors.Join(errs...)
}
