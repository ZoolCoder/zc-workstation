package main

import (
	"fmt"
	"io"
	"text/tabwriter"

	"github.com/zoolcoder/zc-workstation/internal/engine"
)

// writeItems prints the inventory as one table, or as JSON.
func writeItems(w io.Writer, rows []engine.TargetItems, asJSON bool) error {
	if asJSON {
		return writeJSON(w, rows)
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "TARGET\tKIND\tNAME\tSTATE\tVERSION\tAPP\tABOUT")
	for _, r := range rows {
		switch {
		case r.Skipped:
			fmt.Fprintf(tw, "%s\t\t\tskipped\t\t\tnot for this system\n", r.Target)
		case r.Error != "":
			fmt.Fprintf(tw, "%s\t\t\terror\t\t\t%s\n", r.Target, r.Error)
		}
		for _, i := range r.Items {
			fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				r.Target, i.Kind, i.Name, i.State, dash(i.Version), dash(i.App), i.Desc)
		}
	}
	return tw.Flush()
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
