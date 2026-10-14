---
name: setup
description: Install zc-workstation, write a first config and check it with doctor. Use when the user asks to "set up", "install" or "get started with" zc-workstation, or when doctor fails.
license: MIT
compatibility: Needs a shell with Homebrew or Go.
---

# Set up

1. Install: `brew install --cask zoolcoder/zc-workstation/zc-workstation`, or `go install github.com/zoolcoder/zc-workstation/cmd/zc-workstation@latest`.
2. Write `zc-workstation.yaml` in the project, or `~/.config/zc-workstation/zc-workstation.yaml`. Start from `zc-workstation.example.yaml`. Each target needs a kebab-case `name`, a `provider` and a `path`.
3. Run `zc-workstation validate`, then `zc-workstation doctor`. Fix every `fail` line before planning.
4. Hand over to the `plan-apply` skill for the first plan.

Never create a target with `prune: true` on a directory the user did not name: prune deletes every file the config does not declare.
