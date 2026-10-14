# zc-workstation

[![ci](https://github.com/ZoolCoder/zc-workstation/actions/workflows/ci.yml/badge.svg)](https://github.com/ZoolCoder/zc-workstation/actions/workflows/ci.yml)
[![docs](https://img.shields.io/badge/docs-manual-informational)](https://zoolcoder.github.io/zc-workstation)

One YAML file says what should exist. `zc-workstation` reads what exists
now, prints the difference, and only if you ask, closes it. Every apply is
verified by planning again.

```console
$ zc-workstation plan -out plan.json
CREATE  notes  README.md      new file, 69 bytes
CREATE  notes  todo/today.md  new file, 41 bytes
$ zc-workstation apply plan.json
done  CREATE notes README.md
done  CREATE notes todo/today.md
applied and verified
```


## Install

```console
$ brew tap zoolcoder/zc-workstation https://github.com/zoolcoder/zc-workstation
$ brew install --cask zc-workstation
```

or `go install github.com/zoolcoder/zc-workstation/cmd/zc-workstation@latest`.

## Use

```console
$ cp zc-workstation.example.yaml zc-workstation.yaml
$ zc-workstation validate
$ zc-workstation plan
$ zc-workstation apply
$ zc-workstation doctor
```

The [manual](https://zoolcoder.github.io/zc-workstation) covers the config,
every command, the admin page and the agent surfaces.

## Develop

```console
$ make lint test build
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
[SECURITY.md](SECURITY.md).
