package settings

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// regData is one value as `reg query` prints it.
type regData struct{ kind, data string }

// String shows a DWORD in decimal, the way the config declares it.
func (v regData) String() string {
	if n, ok := v.dword(); ok {
		return strconv.FormatUint(n, 10)
	}
	return v.data
}

func (v regData) dword() (uint64, bool) {
	if v.kind != "REG_DWORD" && v.kind != "REG_QWORD" {
		return 0, false
	}
	n, err := strconv.ParseUint(strings.TrimPrefix(v.data, "0x"), 16, 64)
	return n, err == nil
}

// regLine is a value line of `reg query`: four spaces, the name, the type
// and the data, each apart by four spaces. An empty string has no data.
var regLine = regexp.MustCompile(`^ {4}(.+?) {4}(REG_[A-Z_]+)(?: {4}(.*))?$`)

// regValue finds name's value in what `reg query KEY /v NAME` prints.
func regValue(out []byte, name string) (regData, bool) {
	for line := range strings.Lines(string(out)) {
		m := regLine.FindStringSubmatch(strings.TrimRight(line, "\r\n"))
		if m != nil && strings.EqualFold(m[1], name) {
			return regData{kind: m[2], data: m[3]}, true
		}
	}
	return regData{}, false
}

// sameReg compares a declared value with what the registry holds: a bool as
// a DWORD of 1 or 0, an integer as a DWORD, and a string as text.
func sameReg(want any, have regData) bool {
	n, isDword := have.dword()
	switch w := want.(type) {
	case bool:
		return isDword && n == map[bool]uint64{true: 1, false: 0}[w]
	case int:
		return isDword && w >= 0 && n == uint64(w)
	}
	return !isDword && have.data == fmt.Sprint(want)
}

// regAddArgs are the reg add arguments that store v with its type; /f
// overwrites without asking.
func regAddArgs(key, name string, v any) []string {
	args := []string{"add", key, "/v", name}
	switch w := v.(type) {
	case bool:
		return append(args, "/t", "REG_DWORD", "/d", map[bool]string{true: "1", false: "0"}[w], "/f")
	case int:
		return append(args, "/t", "REG_DWORD", "/d", strconv.Itoa(w), "/f")
	}
	return append(args, "/t", "REG_SZ", "/d", fmt.Sprint(v), "/f")
}
