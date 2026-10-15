# TODO

Concrete open work, in rough priority order. The [roadmap](docs/ROADMAP.md)
says where the project is heading; this file says what to pick up next.
Items marked *good first change* need no knowledge of the engine.

Take an item by opening an issue that names it, so two people do not do the
same work. Remove the line in the pull request that finishes it.

## Release

- [ ] Apply the repository settings: run `scripts/harden.sh` once with admin
      rights. It creates `develop`, makes it the default branch, applies the
      rulesets and turns on Dependabot alerts, security updates and private
      vulnerability reporting.
- [ ] Cut `v0.1.0`: a `release/0.1.0` branch, the changelog under the
      version, merge into `main`, tag. Check that the release workflow
      publishes the binaries and opens the Homebrew cask pull request.
- [ ] Install from the cask on a clean macOS VM and run `bootstrap.sh` end to
      end.

## ZCBar and ZC Care

- [ ] Similar Images in My Clutter: group photos that look alike, keep the
      best, Trash the rest after a confirm.
- [ ] Browser privacy data in Protection: history, cookies and caches per
      browser, cleared only for a browser that is closed.
- [ ] Sign ZCBar with a Developer ID and notarise it, so Full Disk Access
      survives an update and Gatekeeper opens it without a warning.
- [ ] Ship ZCBar in the release: a cask for the app next to the CLI's.
- [ ] Redraw the app icon in the electric blue brand colour; it still uses
      the old violet tile.

## Linux (phase 2)

- [ ] `services` on systemd: user units and timers.
- [ ] `settings` on GNOME: gsettings keys, with a light and dark theme.
- [ ] keyd for Caps Lock as Escape and Hyper.
- [ ] `apply` then `doctor` in Ubuntu LTS and Fedora containers in CI.

## Windows (phase 3)

- [ ] `settings` through the registry, `services` through Task Scheduler.
- [ ] A PowerShell profile with starship and atuin, and WezTerm config.
- [ ] `apply` then `doctor` on a Windows runner in CI.

## Docs

- [ ] Getting started pages per system: macOS, Linux, Windows.
- [ ] Generate the command reference from the CLI's help, so it cannot drift.
- [ ] *Good first change:* a toolbox page for a tool in the Brewfile that has
      none yet, under `docs/modules/ROOT/pages/toolbox/`.
- [ ] *Good first change:* a screenshot of the dashboard for `ui.adoc`, with
      no personal data in it.

## Quality

- [ ] A clean-machine test on a tart macOS VM, run before each release.
- [ ] *Good first change:* a `doctor` check for a common misconfiguration you
      hit, with its fix text and a test.
