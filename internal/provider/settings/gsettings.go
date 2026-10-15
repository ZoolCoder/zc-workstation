package settings

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// gvariant writes a declared value as GVariant text, which gsettings set
// parses by the key's type: a string is quoted, a float always has a point,
// and a list is an array of strings.
func gvariant(v any) string {
	switch w := v.(type) {
	case bool:
		return strconv.FormatBool(w)
	case int:
		return strconv.Itoa(w)
	case float64:
		s := strconv.FormatFloat(w, 'g', -1, 64)
		if !strings.ContainsAny(s, ".e") {
			s += ".0"
		}
		return s
	case []any:
		if len(w) == 0 {
			return "@as []"
		}
		items := make([]string, len(w))
		for i, it := range w {
			items[i] = quote(fmt.Sprint(it))
		}
		return "[" + strings.Join(items, ", ") + "]"
	}
	return quote(fmt.Sprint(v))
}

func quote(s string) string {
	return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(s) + "'"
}

// typed matches the type gsettings get prints before a number that is not a
// plain int32, such as uint32 5, and the @as before an empty array.
var typed = regexp.MustCompile(`^(u?int(16|32|64)|byte|@[a-z]+) `)

// sameGVariant compares a declared value with what gsettings get prints.
// gsettings quotes a string in double quotes when it holds a single one.
func sameGVariant(want any, have string) bool {
	have = typed.ReplaceAllString(strings.TrimSpace(have), "")
	if s, ok := want.(string); ok && len(have) >= 2 && (have[0] == '"' || have[0] == '\'') {
		unq := strings.NewReplacer(`\\`, `\`, `\'`, `'`, `\"`, `"`).Replace(have[1 : len(have)-1])
		return unq == s
	}
	if l, ok := want.([]any); ok && len(l) == 0 {
		return have == "[]"
	}
	if f, ok := want.(float64); ok {
		h, err := strconv.ParseFloat(have, 64)
		return err == nil && h == f
	}
	return have == gvariant(want)
}
