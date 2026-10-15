#!/usr/bin/env bash
# Leaves optional modules out of a tool made from zc-workstation.
#
#   scripts/select-modules.sh --list
#   scripts/select-modules.sh --remove ui,mcp
#   --no-verify   skip go vet and go test afterwards
#
# Optional commands register themselves in init(), so deleting their file
# removes the command; no Go file needs editing.
set -euo pipefail
cd "$(dirname "$0")/.."

MODULES=(ui mcp docs release)
NAME="$(sed -n 's|^module .*/||p' go.mod)"
CMD="cmd/$NAME"

describe() {
  case "$1" in
    ui) echo "admin page: $NAME ui, internal/ui" ;;
    mcp) echo "agent surfaces: $NAME mcp, skills, plugin, hook, commands, adapters, evals" ;;
    docs) echo "Antora docs site, its workflow and .webscan.json" ;;
    release) echo "goreleaser, release workflow, Homebrew cask" ;;
  esac
}

usage() { sed -n '2,7p' "$0"; exit 1; }

# drop_target FILE NAME: deletes a Makefile target and its recipe.
drop_target() {
  awk -v t="$2" '$0 ~ "^"t":" {skip=1; next} skip && /^$/ {skip=0; next} !skip' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  sed -E -i '' "/^\.PHONY/ s/ $2( |\$)/\1/" "$1" 2>/dev/null || sed -E -i "/^\.PHONY/ s/ $2( |\$)/\1/" "$1"
}

# drop_section FILE HEADING: deletes a markdown section up to the next heading.
drop_section() {
  awk -v h="$2" '$0 == h {skip=1; next} skip && /^## / {skip=0} !skip' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# drop_lines FILE PATTERN: deletes matching lines, if the file exists.
drop_lines() {
  [ -f "$1" ] || return 0
  grep -v -- "$2" "$1" > "$1.tmp" || true
  mv "$1.tmp" "$1"
}

remove() {
  case "$1" in
    ui)
      rm -rf "$CMD/ui.go" internal/ui docs/modules/ROOT/pages/ui.adoc
      drop_target Makefile ui
      drop_lines docs/modules/ROOT/nav.adoc 'xref:ui.adoc'
      drop_lines docs/modules/ROOT/pages/commands.adoc '^| `ui`'
      drop_lines .webscan.json '/ui.html'
      drop_lines .github/CODEOWNERS '/internal/ui/'
      # The ui-goes-through-the-engine rule: its comment, name and body.
      awk '/# The UI reaches providers/ {skip=1}
           skip && /ui-goes-through-the-engine:/ {inrule=1; next}
           inrule && NF && match($0, /^ */) && RLENGTH <= 8 {skip=0; inrule=0}
           !skip' .golangci.yml > .golangci.yml.tmp && mv .golangci.yml.tmp .golangci.yml
      ;;
    mcp)
      rm -rf "$CMD/mcp.go" "$CMD/mcp_test.go" skills .claude-plugin hooks commands adapters evals .mcp.json \
        docs/modules/ROOT/pages/agents.adoc
      drop_target Makefile evals
      drop_lines docs/modules/ROOT/nav.adoc 'xref:agents.adoc'
      drop_lines docs/modules/ROOT/pages/commands.adoc '^| `mcp`'
      drop_lines .webscan.json '/agents.html'
      drop_lines .github/CODEOWNERS '^/skills/'
      drop_lines .github/CODEOWNERS '^/hooks/'
      ;;
    docs)
      rm -rf docs/antora.yml docs/modules docs/redirects.mjs antora-playbook.yml antora-assembler.yml \
        Gemfile Gemfile.lock package.json package-lock.json .github/workflows/docs.yml .webscan.json
      drop_target Makefile docs-serve
      drop_target Makefile docs
      drop_section CONTRIBUTING.md '## Docs'
      ;;
    release)
      rm -rf .goreleaser.yaml .github/workflows/release.yml Casks
      ;;
    *) echo "unknown module: $1 (have: ${MODULES[*]})" >&2; exit 1 ;;
  esac
  echo "==> removed $1"
}

[ $# -gt 0 ] || usage
VERIFY=1
LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list) for m in "${MODULES[@]}"; do printf '%-8s %s\n' "$m" "$(describe "$m")"; done; exit 0 ;;
    --remove) LIST="$2"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    *) usage ;;
  esac
done
[ -n "$LIST" ] || usage

IFS=',' read -ra picked <<< "$LIST"
for m in "${picked[@]}"; do
  m="${m// /}"
  [ -n "$m" ] && remove "$m"
done

go mod tidy || echo "warning: go mod tidy failed; run it by hand" >&2
if [ $VERIFY -eq 1 ]; then
  echo "==> verifying"
  go vet ./...
  go test ./...
fi
