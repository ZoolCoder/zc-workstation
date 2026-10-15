package packages

import (
	"context"
	"fmt"
	"strings"

	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/manifest"
)

// Remove uninstalls kind:name and drops its line from t's manifest. An item
// the manifest does not declare is still uninstalled, so leftovers go through
// the tool too; an App Store app that is not declared is named by its id.
func (p Provider) Remove(ctx context.Context, t config.Target, kind, name string) error {
	m := managers[p.Manager(t)]
	if m.remove == nil || m.key == nil {
		return fmt.Errorf("zc-workstation does not remove %s packages", p.Manager(t))
	}
	if kind == "" {
		kind = "brew"
	}
	data, err := readFile(t.File)
	if err != nil {
		return err
	}
	items, _, err := m.parse(data)
	if err != nil {
		return fmt.Errorf("%s: %w", t.File, err)
	}
	i := item{Kind: kind, Name: name, ID: name}
	for _, d := range items {
		if d.Kind == kind && strings.EqualFold(d.Name, name) {
			i = d
		}
	}
	if err := m.remove(p.r, i)(ctx); err != nil {
		return err
	}
	if data, ok := manifest.Drop(data, m.key, kind+":"+i.Name); ok {
		return writeFile(t.File, data)
	}
	return nil
}
