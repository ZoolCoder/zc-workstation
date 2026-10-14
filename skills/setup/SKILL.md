---
name: setup
description: Install zc-workstation, write a first config and check it with doctor. Use when the user asks to "set up", "install" or "get started with" zc-workstation, or when doctor fails.
license: MIT
compatibility: Needs macOS, Linux or Windows, with Homebrew, a release package, or Go.
---

# Set up

1. Install: `brew install --cask zoolcoder/zc-workstation/zc-workstation`, or `go install github.com/zoolcoder/zc-workstation/cmd/zc-workstation@latest`.
2. Write `~/.config/zc-workstation/zc-workstation.yaml`, or keep it in the user's dotfiles repository and pass `-config`. Start from `zc-workstation.example.yaml`. Each target needs a kebab-case `name` and a `provider`: `packages` and `tools` need a `file`, `dotfiles` needs a `source`. Use `os` to limit a target to `darwin`, `linux` or `windows`.
3. Run `zc-workstation validate`, then `zc-workstation doctor`. Fix every `fail` line before planning. A `program` line that fails names a tool to install: Homebrew, chezmoi or mise. Ask before installing it.
4. Hand over to the `plan-apply` skill for the first plan.

Never point a `dotfiles` target at the user's real home directory while another tool (such as an older dotfiles script) still manages it: set `destination` to a scratch directory until the user switches over.

Never create a target with `prune: true` on a directory the user did not name: prune deletes every file the config does not declare.
