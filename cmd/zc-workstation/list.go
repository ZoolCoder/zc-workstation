package main

import (
	"fmt"
	"io"
	"slices"
	"strings"
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
				r.Target, i.Kind, i.Name, i.State, versions(i), dash(i.App), i.Desc)
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

// filterItems keeps the items whose state and kind are in the comma lists;
// an empty list keeps every value.
func filterItems(rows []engine.TargetItems, states, kinds string) []engine.TargetItems {
	if states == "" && kinds == "" {
		return rows
	}
	keep := func(list, v string) bool {
		return list == "" || slices.Contains(strings.Split(list, ","), v)
	}
	// A skipped target has nothing to match, so a filtered list leaves it out.
	rows = slices.DeleteFunc(rows, func(r engine.TargetItems) bool { return r.Skipped })
	for n, r := range rows {
		var items []engine.Item
		for _, i := range r.Items {
			if keep(states, i.State) && keep(kinds, i.Kind) {
				items = append(items, i)
			}
		}
		rows[n].Items = items
	}
	return rows
}

// versions is the installed version, and the newer one when there is one.
func versions(i engine.Item) string {
	if i.Latest != "" {
		return dash(i.Version) + " -> " + i.Latest
	}
	return dash(i.Version)
}
