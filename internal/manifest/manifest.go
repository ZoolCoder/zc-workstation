// Package manifest reads and edits the comments people write in line-based
// manifests, such as a Brewfile, a package list or a mise.toml. A comment
// line that opens a block, after a blank line or at the top of the file, is
// that block's section heading; a comment block at the top that a blank line
// ends is about the whole file instead. A comment at the end of an entry's
// line says why the entry is there.
package manifest

import (
	"fmt"
	"slices"
	"strings"
)

// Note is what the comments say about one entry.
type Note struct {
	Section string `json:"section,omitempty"`
	Why     string `json:"why,omitempty"`
}

// Key reads an entry line, without its trailing comment, and returns the
// entry's key, or false for a line that is not an entry.
type Key func(line string) (string, bool)

// Notes maps each entry's key to its section and why.
func Notes(data []byte, key Key) map[string]Note {
	notes := map[string]Note{}
	for _, l := range scan(data) {
		if k, ok := key(l.entry); ok {
			notes[k] = Note{Section: l.section, Why: l.why}
		}
	}
	return notes
}

// Sections lists the section headings in file order.
func Sections(data []byte) []string {
	var out []string
	for _, l := range scan(data) {
		if l.heading && !slices.Contains(out, l.section) {
			out = append(out, l.section)
		}
	}
	return out
}

// Insert adds entry as the last line of section's block, matched without
// regard to case. The empty section is the block above the first heading.
// A section the file does not have is appended as a new block.
func Insert(data []byte, section, entry string) []byte {
	lines := scan(data)
	at := -1
	for n, l := range lines {
		if strings.EqualFold(l.section, section) && l.text != "" {
			at = n
		}
	}
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	switch {
	case at >= 0:
		raw = slices.Insert(raw, at+1, entry)
	case section == "":
		raw = slices.Insert(raw, 0, entry, "")
	default:
		raw = append(raw, "", "# "+section, entry)
	}
	return []byte(strings.Join(raw, "\n") + "\n")
}

// Drop removes the entry whose key is want, matched without regard to case,
// and reports whether there was one.
func Drop(data []byte, key Key, want string) ([]byte, bool) {
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	for n, l := range scan(data) {
		if k, ok := key(l.entry); ok && strings.EqualFold(k, want) {
			return []byte(strings.Join(slices.Delete(raw, n, n+1), "\n") + "\n"), true
		}
	}
	return data, false
}

// Line is an entry and its why, as one manifest line.
func Line(entry, why string) (string, error) {
	if strings.ContainsAny(why, "\r\n") {
		return "", fmt.Errorf("the why must be one line")
	}
	if why = strings.TrimSpace(why); why == "" {
		return entry, nil
	}
	return entry + " # " + why, nil
}

type line struct {
	text, entry, why, section string
	heading                   bool
}

func scan(data []byte) []line {
	raw := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	out := make([]line, len(raw))
	section, blank, top := "", true, true
	for n, r := range raw {
		t := strings.TrimSpace(r)
		l := line{text: t}
		switch {
		case t == "":
			blank = true
			l.section = section
			out[n] = l
			continue
		case strings.HasPrefix(t, "#"):
			if blank && (!top || !fileComment(raw[n:])) {
				section, l.heading = strings.TrimSpace(strings.TrimLeft(t, "#")), true
			}
		default:
			l.entry, l.why = split(t)
		}
		blank, top = false, false
		l.section = section
		out[n] = l
	}
	return out
}

// fileComment reports whether the comment block that starts lines ends in a
// blank line or the end of the file.
func fileComment(lines []string) bool {
	for _, l := range lines {
		if t := strings.TrimSpace(l); !strings.HasPrefix(t, "#") {
			return t == ""
		}
	}
	return true
}

// split cuts a line at its first # outside double quotes.
func split(t string) (entry, why string) {
	quoted := false
	for n, c := range t {
		switch {
		case c == '"':
			quoted = !quoted
		case c == '#' && !quoted:
			return strings.TrimSpace(t[:n]), strings.TrimSpace(t[n+1:])
		}
	}
	return t, ""
}
