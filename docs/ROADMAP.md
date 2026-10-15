# Roadmap

The full plan, with the decisions and the projects reused from GitHub, is in
[docs/modules/ROOT/pages/roadmap.adoc](modules/ROOT/pages/roadmap.adoc).

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

## Next

- ZC Care: Similar Images in My Clutter, and browser privacy data.
- Phase 2, Linux: Ubuntu LTS and Fedora.
- Phase 3, native Windows: winget, PowerShell, WezTerm, PowerToys.
- Phase 4: retire aurora-mac.

## Not planned

- Applying from an agent without a person's yes to the plan.
- A plan that performs writes.
- Managing servers or fleets of machines.
- Nix or home-manager.
