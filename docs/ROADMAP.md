# Roadmap

The full plan, with the decisions and the projects reused from GitHub, is in
[docs/modules/ROOT/pages/roadmap.adoc](modules/ROOT/pages/roadmap.adoc).

## Next

- Phase 1, macOS parity with aurora-mac: move its config into `home/` as
  chezmoi source state, and write the dotfiles, packages, tools, settings and
  services providers. Then port `doctor.sh`, `catalog` and the overlay.
- Phase 2, Linux: Ubuntu LTS and Fedora.
- Phase 3, native Windows: winget, PowerShell, WezTerm, PowerToys.
- Phase 4: archive aurora-mac.

## Not planned

- Applying from an agent without a person's yes to the plan.
- A plan that performs writes.
- Managing servers or fleets of machines.
- Nix or home-manager.
