#!/usr/bin/env bash
#
# Installs the vhosty CLI into ~/.vhosty and puts it on your PATH.
#
#   From a clone:   ./install.sh
#   From the web:   curl -fsSL https://raw.githubusercontent.com/vhostyhq/vhosty/main/install.sh | bash
#
# From the web it installs the latest release. VHOSTY_REF picks another:
# a tag (v0.3.0), or main for changes that aren't released yet.
#
# Then run: vhosty setup

set -euo pipefail

REPO="${VHOSTY_REPO:-vhostyhq/vhosty}"
REF="${VHOSTY_REF:-}"
VHOSTY_DIR="${VHOSTY_DIR:-$HOME/.vhosty}"
LINK="/usr/local/bin/vhosty"

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
ok()  { printf "  %s✓%s %s\n" "$G" "$N" "$*"; }
warn() { printf "  %s!%s %s\n" "$Y" "$N" "$*"; }
die() { printf "%serror:%s %s\n" "$R" "$N" "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin|Linux) ;;
  *) die "vhosty supports macOS and Linux" ;;
esac

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
  if [ -z "$REF" ]; then
    # github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>
    REF="$(curl -fsSLI --connect-timeout 10 --max-time 15 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
    case "$REF" in
      */releases/tag/*) REF="${REF##*/releases/tag/}" ;;
      *) warn "Couldn't find the latest release, so installing main"; REF="main" ;;
    esac
  fi
  base="https://raw.githubusercontent.com/$REPO/$REF"
  # Downloaded next to the installed files, checked, then renamed over them
  curl -fsSL --retry 2 --max-time 60 "$base/bin/vhosty" -o "$VHOSTY_DIR/bin/.vhosty.new" \
    || { rm -f "$VHOSTY_DIR/bin/.vhosty.new"; die "Download failed. If the repo is private, clone it and run ./install.sh instead."; }
  curl -fsSL --retry 2 --max-time 60 "$base/completions/_vhosty" -o "$VHOSTY_DIR/completions/._vhosty.new" \
    || rm -f "$VHOSTY_DIR/completions/._vhosty.new"
  grep -q '^VHOSTY_VERSION=' "$VHOSTY_DIR/bin/.vhosty.new" && bash -n "$VHOSTY_DIR/bin/.vhosty.new" 2>/dev/null \
    || { rm -f "$VHOSTY_DIR/bin/.vhosty.new"; die "What came from $REF doesn't look like vhosty. Not installing it."; }
  # Releases from 0.5.0 on publish SHA256SUMS
  case "$REF" in
    v[0-9]*)
      if sums="$(curl -fsSL --retry 2 --max-time 20 "https://github.com/$REPO/releases/download/$REF/SHA256SUMS" 2>/dev/null)"; then
        for pair in "bin/.vhosty.new vhosty" "completions/._vhosty.new _vhosty"; do
          f="$VHOSTY_DIR/${pair% *}"; n="${pair#* }"
          [ -f "$f" ] || continue
          want="$(printf '%s\n' "$sums" | awk -v n="$n" '$2 == n || $2 == "*" n {print $1; exit}')"
          if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$f" | cut -d' ' -f1)"; else got="$(shasum -a 256 "$f" | cut -d' ' -f1)"; fi
          [ -n "$want" ] && [ "$got" = "$want" ] \
            || { rm -f "$VHOSTY_DIR/bin/.vhosty.new" "$VHOSTY_DIR/completions/._vhosty.new"; die "$n from $REF doesn't match its published checksum. Not installing it."; }
        done
        ok "checksums match"
      fi ;;
  esac
  mv "$VHOSTY_DIR/bin/.vhosty.new" "$VHOSTY_DIR/bin/vhosty"
  [ ! -f "$VHOSTY_DIR/completions/._vhosty.new" ] || mv "$VHOSTY_DIR/completions/._vhosty.new" "$VHOSTY_DIR/completions/_vhosty"
  ok "downloaded $REPO@$REF"
fi
chmod +x "$VHOSTY_DIR/bin/vhosty"

# Put it on the PATH: ~/.local/bin when it's already on the PATH (most Linux
# setups), otherwise /usr/local/bin
case ":$PATH:" in
  *":$HOME/.local/bin:"*) LINK="$HOME/.local/bin/vhosty"; mkdir -p "$HOME/.local/bin" ;;
esac
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

# Already set up: regenerate the config with the new version, as
# `vhosty update self` does, so its changes take effect
if [ -f "$VHOSTY_DIR/config" ]; then
  printf "\n%sApplying the new version%s\n" "$B" "$N"
  "$VHOSTY_DIR/bin/vhosty" rebuild </dev/null || printf "  Couldn't rebuild. Run: vhosty rebuild\n"
else
  printf "\n%sNext:%s vhosty setup\n" "$B" "$N"
fi
