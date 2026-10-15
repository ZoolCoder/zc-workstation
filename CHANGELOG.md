# Changelog

Notable changes, newest first. Versions follow [semver](https://semver.org);
before 1.0 a minor bump may change the config format, and any that does says so
here with what to edit.

## Unreleased

### ZCBar and ZC Care

- ZCBar, a macOS menu bar app over the CLI, with an app icon and a ⌃⌥Z
  hotkey. Its panel has five tabs: Mac (vitals, free up, advice), Overview,
  Updates, Health and Services. It shows its count in SketchyBar and opens
  through `zcbar://` URLs.
- ZC Care, ZCBar's window, with these modules:
  - Smart Care.
  - Cleanup, including the clutter AI tools leave behind.
  - Protection: Gatekeeper, background apps, privacy permissions.
  - Performance: login items and maintenance tasks.
  - Applications: uninstall, adopt into Homebrew, leftovers.
  - My Clutter and Space Lens.
  - Developer: idle project dependencies, local AI models.
  - My Tools.
  - My Activity, which logs what was freed.
- Each module has its own colour and an intro page. Screen Cleaning Mode locks
  the keyboard while you wipe the screens.
- CI builds and tests ZCBar on a macOS runner.

### CLI

- `add` declares an item with a why-note. `remove` uninstalls an item and
  drops it from its manifest.
- `capture` writes a manifest from the machine. `list` shows outdated and
  undeclared items, filtered by `-state` and `-kind`.
- `-upgrade` and `-only` on `plan` and `apply`.
- A macOS password dialog for `sudo` when there is no terminal.
- Apply keeps going after a failed change and reports it.
- `doctor` checks the macOS security settings: FileVault, firewall, screen
  lock, Gatekeeper, SIP, updates, File Sharing, Touch ID and exposed servers.

### Providers

- `packages` (brew, mas, apt, dnf, winget), `dotfiles` (chezmoi) and `tools`
  (mise).
  - `packages` adopts apps already installed and trusts a third-party tap
    after adding it.
- `settings` (macOS defaults) and `services` (brew services, launchd agents).
- `desktop`: the wallpaper on every Space and a WebViewScreenSaver page,
  built from source.
- The `os` filter, so one config serves every machine.

### Setup and look

- `bootstrap.sh` sets up a new Mac from a config repo in one command.
- The ZoolCoder theme for the shell, bar and tools, a wallpaper and a screen
  saver.
- The dashboard has a machine page and an inventory, with an orbit theme. It
  caches live status and runs probes in parallel.

### First scaffold

- `plan`, `apply`, `status`, `validate` and `doctor` over a YAML config, with
  saved plans and verification after every apply.
- The `localdir` provider.
- `ui`: the admin page. `mcp`: the MCP server, skills and plugin.
