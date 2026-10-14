#!/usr/bin/env bash
# Sets up a new Mac from a config repo in one run: installs Homebrew and the tools zc-workstation needs,
# clones zc-workstation and the config repo into ~/Developer/Tools, builds zc-workstation, then applies the config.
# Usage: bootstrap.sh OWNER/CONFIG-REPO
#   curl -fsSL https://raw.githubusercontent.com/ZoolCoder/zc-workstation/main/bootstrap.sh | bash -s -- OWNER/CONFIG-REPO
# Safe to run again: what is already there is kept, and apply only changes what differs.
set -euo pipefail

config_repo=${1:-${ZC_CONFIG_REPO:-}}
[[ -n $config_repo ]] || { echo "usage: bootstrap.sh OWNER/CONFIG-REPO" >&2; exit 1; }
[[ $(uname -s) == Darwin ]] || { echo "bootstrap.sh is for macOS; on Linux, build zc-workstation and run apply." >&2; exit 1; }

tools="$HOME/Developer/Tools"
tool_dir="$tools/zc-workstation"
config_dir="$tools/$(basename "$config_repo")"
# Clone sources; the VM test points these at mounted copies.
tool_from=${ZC_TOOL_FROM:-https://github.com/ZoolCoder/zc-workstation.git}
config_from=${ZC_CONFIG_FROM:-}

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }

if ! command -v brew >/dev/null && [[ ! -x /opt/homebrew/bin/brew ]]; then
  step "Installing Homebrew (asks for your password; also installs the Xcode command line tools)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

step "Installing what zc-workstation needs"
brew install git gh go chezmoi mise

if [[ -z $config_from ]]; then
  # The config repo is usually private, so git needs a GitHub login first.
  gh auth status >/dev/null 2>&1 || { step "Logging in to GitHub"; gh auth login --git-protocol https --web; }
  gh auth setup-git
  config_from="https://github.com/$config_repo.git"
fi

mkdir -p "$tools"
for pair in "$tool_from|$tool_dir" "$config_from|$config_dir"; do
  from=${pair%%|*} dir=${pair#*|}
  if [[ -d $dir/.git ]]; then
    echo "Keeping $dir"
  else
    step "Cloning $from"
    git clone --quiet "$from" "$dir"
  fi
done

step "Building zc-workstation"
make -C "$tool_dir" install
export PATH="$HOME/.local/bin:$PATH"
export ZC_WORKSTATION_CONFIG="$config_dir/zc-workstation.yaml"
# mise reads only configs you trust; this one is yours.
[[ -f $config_dir/mise.toml ]] && mise trust --quiet "$config_dir/mise.toml"

step "Plan"
zc-workstation plan
step "Applying"
zc-workstation apply
# Targets planned before the packages arrived, such as runtimes, are finished by a second pass.
if ! zc-workstation plan -exit-code >/dev/null 2>&1; then
  zc-workstation apply
fi

step "Done"
zc-workstation status
cat <<'MSG'

Left for you, once:
  * Log out and back in, then run: zc-workstation apply   (loads the commit signing key)
  * Pick WebViewScreenSaver in System Settings > Screen Saver
  * Open a new terminal to get the new shell
MSG
