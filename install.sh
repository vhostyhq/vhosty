#!/usr/bin/env bash
#
# Installs the vhosty CLI into ~/.vhosty and puts it on your PATH.
#
#   From a clone:   ./install.sh
#   From the web:   curl -fsSL https://raw.githubusercontent.com/zacksmash/vhosty/main/install.sh | bash
#
# Then run: vhosty setup

set -euo pipefail

REPO="${VHOSTY_REPO:-zacksmash/vhosty}"
REF="${VHOSTY_REF:-main}"
VHOSTY_DIR="${VHOSTY_DIR:-$HOME/.vhosty}"
LINK="/usr/local/bin/vhosty"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; R=""; N=""; fi
ok()  { printf "  %s✓%s %s\n" "$G" "$N" "$*"; }
die() { printf "%serror:%s %s\n" "$R" "$N" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "vhosty supports macOS only for now"

printf "%sInstalling vhosty%s\n" "$B" "$N"
mkdir -p "$VHOSTY_DIR/bin" "$VHOSTY_DIR/completions"

# Use the files next to this script when run from a clone; otherwise download them
src=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$src/bin/vhosty" ] || src=""
fi

if [ -n "$src" ]; then
  cp "$src/bin/vhosty" "$VHOSTY_DIR/bin/vhosty"
  cp "$src/completions/_vhosty" "$VHOSTY_DIR/completions/_vhosty"
  ok "copied from $src"
else
  base="https://raw.githubusercontent.com/$REPO/$REF"
  curl -fsSL "$base/bin/vhosty" -o "$VHOSTY_DIR/bin/vhosty" \
    || die "Download failed. If the repo is private, clone it and run ./install.sh instead."
  curl -fsSL "$base/completions/_vhosty" -o "$VHOSTY_DIR/completions/_vhosty" || true
  ok "downloaded $REPO@$REF"
fi
chmod +x "$VHOSTY_DIR/bin/vhosty"

# Put it on the PATH
linked=0
if [ -d "$(dirname "$LINK")" ] && [ -w "$(dirname "$LINK")" ]; then
  ln -sf "$VHOSTY_DIR/bin/vhosty" "$LINK" && linked=1
else
  printf "  Linking %s (asks for your password)\n" "$LINK"
  if sudo mkdir -p "$(dirname "$LINK")" && sudo ln -sf "$VHOSTY_DIR/bin/vhosty" "$LINK"; then linked=1; fi
fi
if [ "$linked" = "1" ]; then
  ok "linked $LINK"
else
  printf "  Couldn't link %s. Add this to your shell profile instead:\n    export PATH=\"%s/bin:\$PATH\"\n" "$LINK" "$VHOSTY_DIR"
fi

printf "\n  Tab completion (zsh): add this to ~/.zshrc, before compinit runs:\n"
printf "    fpath=(%s/completions \$fpath)\n" "$VHOSTY_DIR"

printf "\n%sNext:%s vhosty setup\n" "$B" "$N"
