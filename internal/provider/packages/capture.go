package packages

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/zoolcoder/zc-workstation/internal/config"
)

// Capture writes a manifest of what this machine has installed on purpose,
// in the format t's manager reads: a Brewfile, or one package per line.
func (p Provider) Capture(ctx context.Context, t config.Target) ([]byte, error) {
	name := p.Manager(t)
	m := managers[name]
	if m.chosen == nil {
		return nil, fmt.Errorf("%s cannot be captured here; run winget export -o %s instead", name, t.File)
	}
	if !p.r.Has(m.program) {
		return nil, errMissing{name: name, program: m.program}
	}
	chosen, err := m.chosen(ctx, p.r)
	if err != nil {
		return nil, err
	}
	if len(chosen) == 0 {
		return nil, errors.New("nothing installed on purpose was found")
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "# Captured by zc-workstation from what this machine has installed.\n")
	for _, i := range chosen {
		switch {
		case name != "brew":
			fmt.Fprintln(&b, i.Name)
		case i.Kind == "mas":
			fmt.Fprintf(&b, "mas %q, id: %s\n", i.Name, i.ID)
		default:
			fmt.Fprintf(&b, "%s %q\n", i.Kind, i.Name)
		}
	}
	return b.Bytes(), nil
}
