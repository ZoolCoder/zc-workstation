# zc-workstation

[![ci](https://github.com/ZoolCoder/zc-workstation/actions/workflows/ci.yml/badge.svg)](https://github.com/ZoolCoder/zc-workstation/actions/workflows/ci.yml)
[![docs](https://img.shields.io/badge/docs-manual-informational)](https://zoolcoder.github.io/zc-workstation)

Set up a developer workstation on macOS, Linux and Windows from one YAML
file: packages, dotfiles and language runtimes. `zc-workstation` reads what
the machine has, prints the difference, and only if you ask, closes it. Every
apply is verified by planning again.

```console
$ zc-workstation plan -out plan.json
CREATE  brew      cask:ghostty           install with brew
CREATE  dotfiles  .gitconfig             add
CREATE  runtimes  python@3.13            install with mise
$ zc-workstation apply plan.json
done  CREATE brew cask:ghostty
done  CREATE dotfiles .gitconfig
done  CREATE runtimes python@3.13
applied and verified
```

It drives the tools that already do each job well:

| Provider   | Manages                    | With                               |
|------------|----------------------------|------------------------------------|
| `packages` | Brewfile, apt, dnf, winget | brew, mas, apt-get, dnf, winget    |
| `dotfiles` | A chezmoi source directory | [chezmoi](https://www.chezmoi.io)  |
| `tools`    | A mise config              | [mise](https://mise.jdx.dev)       |
| `localdir` | Files written in the config | itself                         |

A target can name the systems it is for (`os: [darwin]`), so one config
describes every machine you own.

## Install

```console
$ brew tap zoolcoder/zc-workstation https://github.com/zoolcoder/zc-workstation
$ brew install --cask zc-workstation
```

Linux `.deb`, `.rpm` and `.apk` packages and Windows zips are on the releases
page, or run
`go install github.com/zoolcoder/zc-workstation/cmd/zc-workstation@latest`.

## Use

```console
$ cp zc-workstation.example.yaml ~/.config/zc-workstation/zc-workstation.yaml
$ zc-workstation validate
$ zc-workstation doctor
$ zc-workstation list      # every package, app, dotfile and runtime, with versions
$ zc-workstation plan
$ zc-workstation apply
$ zc-workstation ui        # the dashboard, on 127.0.0.1 only
```

The [manual](https://zoolcoder.github.io/zc-workstation) covers setup per
system, the config, each provider, every command, the dashboard and the agent
surfaces.

## Develop

```console
$ make lint test build
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
[SECURITY.md](SECURITY.md).
