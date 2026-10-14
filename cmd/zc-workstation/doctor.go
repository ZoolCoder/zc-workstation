package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"

	"github.com/zoolcoder/toolshell/doctor"
	"github.com/zoolcoder/zc-workstation/internal/config"
	"github.com/zoolcoder/zc-workstation/internal/engine"
)

// runDoctor checks the install: the binary on PATH, the config, and that
// every target's live state can be read.
func runDoctor(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	path := flags.String("config", "", "config file")
	asJSON := flags.Bool("json", false, "machine-readable report")
	if err := flags.Parse(args); err != nil {
		return err
	}
	*path = findConfig(*path)

	r := doctor.New(version)
	r.AddCheck(doctor.Binary(name))
	host, _ := os.Hostname()
	r.Add("system", doctor.OK, fmt.Sprintf("%s %s/%s", host, runtime.GOOS, runtime.GOARCH))
	cfg, err := config.Load(*path, nil)
	r.Err("config", err, fmt.Sprintf("%s, %d target(s)", *path, len(cfg.Targets)))
	if err == nil {
		eng, err := engine.New(cfg, engine.Default(), nil)
		if err != nil {
			r.Add("targets", doctor.Fail, err.Error())
		} else {
			for _, p := range eng.Programs() {
				if path, err := exec.LookPath(p); err != nil {
					r.Add("program "+p, doctor.Fail, "not on PATH")
				} else {
					r.Add("program "+p, doctor.OK, path)
				}
			}
			for _, st := range eng.Status(context.Background()) {
				switch {
				case st.Error != "":
					r.Add("target "+st.Target, doctor.Fail, st.Error)
				case st.Skipped || st.InSync():
					r.Add("target "+st.Target, doctor.OK, st.Summary)
				default:
					r.Add("target "+st.Target, doctor.Warn, st.Summary)
				}
			}
		}
	}
	return r.Write(stdout, *asJSON)
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
