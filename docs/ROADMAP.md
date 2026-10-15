# Roadmap

The full plan, with the decisions and the projects reused from GitHub, is in
[docs/modules/ROOT/pages/roadmap.adoc](modules/ROOT/pages/roadmap.adoc). The
concrete next tasks are in [TODO.md](../TODO.md).

## Done

- The `packages` (brew, mas, apt, dnf, winget), `dotfiles` (chezmoi) and
  `tools` (mise) providers, the `os` filter, and the dashboard.
- Phase 1, macOS parity with aurora-mac:
  - the `settings`, `services` and `desktop` providers
  - security checks in `doctor`
  - the config in a private repo
  - `bootstrap.sh` for a new Mac
- `list`, `capture`, `add`, `remove`, `-upgrade` and `-only`.
- ZCBar, the menu bar app, and ZC Care, its window that cleans, protects and
  tunes the Mac.
- The MCP server and the Claude Code plugin, with adapters for other agents.
- The toolbox section of the manual: a page per tool in the reference setup.

## Now: the first release

- Apply the repository settings and rulesets (`scripts/harden.sh`).
- `v0.1.0`: binaries, the Homebrew cask, Linux packages and Windows zips.
- A clean-machine run of `bootstrap.sh` on a macOS VM.

## Next

- ZC Care: Similar Images in My Clutter, and browser privacy data.
- ZCBar signed with a Developer ID and notarised, and shipped as a cask.
- Phase 2, Linux: systemd timers, gsettings and keyd, tested on Ubuntu LTS
  and Fedora.
- Phase 3, native Windows: registry settings, Task Scheduler, PowerShell,
  WezTerm.

## Later

- Per-system getting started pages and a generated command reference.
- Phase 4: retire aurora-mac.

## Not planned

- Applying from an agent without a person's yes to the plan.
- A plan that performs writes.
- Managing servers or fleets of machines.
- Nix or home-manager.
