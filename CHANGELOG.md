# Changelog

Notable changes, newest first. Versions follow [semver](https://semver.org);
before 1.0 a minor bump may change the config format, and any that does says so
here with what to edit.

## Unreleased

### Watch, history and upgrade

- `upgrade` saves what is outdated, then upgrades it, so `review` can say
  what moved.
- `history` lists every apply, from the terminal, the dashboard or an agent,
  and each change in drift.
- `drift` counts what differs from the config and saves it; `drift -plist`
  prints a launchd agent that checks every morning. ZCBar, SketchyBar and
  the dashboard show the count.
- The dashboard shows the drift watch and recent activity.
- The manual's command reference is the usage text, checked by a test.

### AI agents

- The `agents` provider writes MCP servers, a rules file and skills into
  Claude Code, Codex, Cursor and Gemini CLI, and pulls Ollama models.
- `doctor` warns about plain-text keys in MCP configs, MCP servers run at
  `@latest`, and Claude Code rules that allow every shell command.
- The MCP server annotates its tools, serves the config, history and
  manifests as resources, refuses plans older than an hour, and logs every
  call to `mcp-audit.jsonl`. New tools: `history` and `drift`.

### Hardening

- My Clutter finds similar images with Vision: resized and resaved copies
  of a photo, the one with the most pixels kept, the rest to the Trash after
  a confirm. Photos libraries are left alone.
- Protection clears each browser's history, cookies or cache: Safari,
  Chrome, Brave, Edge, Arc, Vivaldi, Chromium and Firefox, only while that
  browser is closed. Bookmarks and passwords stay.
- Releases ship ZCBar too: a universal app, attested, with a `zcbar` cask
  in the tap (`brew install --cask zcbar`).
- `doctor` checks SSH keys without a passphrase, commit signing, secrets in
  the shell history (through gitleaks, redacted), Remote Login, Screen
  Sharing, automatic login and AirDrop.
- Releases are signed with cosign, carry an SBOM and SLSA build provenance;
  the security page says how to verify one.

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

- `settings` runs on GNOME: `gsettings` keys under a target with
  `os: [linux]`, such as a dark or light `color-scheme`.
- `services` runs on Linux: systemd user units and timers under `agents`,
  enabled and started with `systemctl --user`.
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
