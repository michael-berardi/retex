#!/bin/sh
# Retex installer for macOS and Linux:
#   curl -fsSL https://github.com/michael-berardi/retex/releases/latest/download/install.sh | sh
# Downloads the signed macOS universal binary or the matching Linux static
# binary, verifies it against the release SHA256SUMS, and installs it into
# $RETEX_HOME/<version> with a symlink in $RETEX_BIN_DIR.
#
# Updater compatibility: `retex update` resolves the symlink and atomically
# replaces the real binary in $RETEX_HOME/<version>, keeping <binary>.previous
# there for rollback. The shim points at $RETEX_HOME/current/retex, so it keeps
# working after an in-app update. Running this installer again creates a fresh
# version folder and repoints `current`.
#
# Environment: RETEX_HOME (default ~/.local/share/retex),
# RETEX_BIN_DIR (default ~/.local/bin), RETEX_VERSION (default: latest,
# e.g. 1.2.3), RETEX_RELEASE_BASE (override download base URL or local dir;
# used by tests and mirrors).
set -eu

REPO="michael-berardi/retex"
HOME_DIR="${RETEX_HOME:-$HOME/.local/share/retex}"
BIN_DIR="${RETEX_BIN_DIR:-$HOME/.local/bin}"
case "$HOME_DIR" in /*) ;; *) HOME_DIR="$(pwd)/$HOME_DIR" ;; esac
case "$BIN_DIR" in /*) ;; *) BIN_DIR="$(pwd)/$BIN_DIR" ;; esac
if [ -n "${RETEX_RELEASE_BASE:-}" ]; then BASE="$RETEX_RELEASE_BASE"
elif [ -n "${RETEX_VERSION:-}" ]; then BASE="https://github.com/$REPO/releases/download/v${RETEX_VERSION#v}"
else BASE="https://github.com/$REPO/releases/latest/download"; fi

say() { printf '%s\n' "$*"; }
die() { printf 'retex install: %s\n' "$*" >&2; exit 1; }

# fetch <url-or-directory/asset> <destination>. A local directory or file://
# URL is supported so the same code path can be tested offline.
fetch() {
  case "$1" in
    file://*) cp "${1#file://}" "$2" || die "cannot read $1" ;;
    /*|./*|../*) cp "$1" "$2" || die "cannot read $1" ;;
    http://*|https://*)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" || die "download failed: $1"
      else die "needs curl or wget"; fi ;;
    *) die "unsupported release base (use https://, file://, or a local directory)" ;;
  esac
}

if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "needs sha256sum or shasum"; fi

platform() {
  case "$(uname -s)" in
    Darwin) OS=darwin; ARCH="$(uname -m)"; ASSET=retex-universal.zip ;;
    Linux)
      OS=linux; ARCH="$(uname -m)"
      case "$ARCH" in x86_64|amd64) ARCH=x86_64 ;; arm64|aarch64) ARCH=aarch64 ;; *) die "unsupported CPU $ARCH" ;; esac
      ASSET="retex-linux-$ARCH.tar.xz" ;;
    *) die "unsupported system $(uname -s)" ;;
  esac
}

expect() { # expect <file> <name> <sums-file>
  want=$(awk -v n="$2" '{ f=$2; sub(/^\*/, "", f); if (f == n) print $1 }' "$3" | head -n 1)
  case "$want" in
    ""|*[!0-9a-fA-F]*) die "no valid checksum for $2 in $(basename "$3")" ;;
  esac
  got=$(sha256 "$1")
  [ "$got" = "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ] || die "checksum mismatch for $2; nothing was installed"
}

extract() { # extract <asset> <destination>
  case "$ASSET" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$TMP/$ASSET" retex -d "$2" || return 1
      else
        command -v ditto >/dev/null 2>&1 || die "needs unzip or ditto"
        mkdir "$TMP/archive"; ditto -x -k "$TMP/$ASSET" "$TMP/archive" || return 1
        cp "$TMP/archive/retex" "$2/retex" || return 1
      fi ;;
    *.tar.xz) tar -xJf "$TMP/$ASSET" -C "$2" retex || return 1 ;;
    *.tar.gz) tar -xzf "$TMP/$ASSET" -C "$2" retex || return 1 ;;
    *) die "unsupported release archive $ASSET" ;;
  esac
  [ -f "$2/retex" ] || return 1
  chmod 755 "$2/retex"
}

swap_link() { # swap_link <target> <link>
  ln -s "$1" "$2.tmp.$$"
  if mv -fT "$2.tmp.$$" "$2" 2>/dev/null || mv -fh "$2.tmp.$$" "$2" 2>/dev/null; then return 0; fi
  rm -f "$2" && mv "$2.tmp.$$" "$2" || { rm -f "$2.tmp.$$"; die "cannot update the link $2"; }
}

main() {
  platform
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/retex-install.XXXXXX") || die "cannot create a temporary folder"
  trap 'rm -rf "$TMP"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  say "Downloading Retex..."
  fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS"
  fetch "$BASE/$ASSET" "$TMP/$ASSET"
  expect "$TMP/$ASSET" "$ASSET" "$TMP/SHA256SUMS"

  # On Linux, xz is the small download; the .tar.gz stays as a compatibility
  # fallback for systems whose tar cannot handle xz.
  mkdir "$TMP/src"
  if ! extract "$ASSET" "$TMP/src"; then
    case "$ASSET" in
      *.tar.xz)
        ASSET="retex-linux-$ARCH.tar.gz"
        fetch "$BASE/$ASSET" "$TMP/$ASSET"
        expect "$TMP/$ASSET" "$ASSET" "$TMP/SHA256SUMS"
        rm -rf "$TMP/src"; mkdir "$TMP/src"
        extract "$ASSET" "$TMP/src" || die "cannot unpack $ASSET" ;;
      *) die "cannot unpack $ASSET" ;;
    esac
  fi
  BIN="$TMP/src/retex"

  # The published macOS binary must carry the same Developer ID requirement
  # the in-app updater enforces. Refuse an unsigned or wrongly signed download.
  if [ "$OS" = darwin ] && command -v codesign >/dev/null 2>&1; then
    codesign --verify --strict \
      -R '=identifier "retex" and anchor apple generic and certificate leaf[subject.OU] = "T63VT9UAY2"' \
      "$BIN" >/dev/null 2>&1 || die "macOS binary is not a Developer ID signed Retex build; nothing was installed"
  fi

  VERSION_RAW=$("$BIN" version 2>/dev/null | head -n 1) || die "the downloaded retex binary does not run"
  VERSION=$(printf '%s' "$VERSION_RAW" | tr -d '\r' | sed -n 's/^[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p')
  case "$VERSION" in *.*.*) ;; *) die "the download reports an invalid version: '$VERSION_RAW'" ;; esac
  if [ -n "${RETEX_VERSION:-}" ]; then
    [ "$VERSION" = "${RETEX_VERSION#v}" ] || die "the download reports $VERSION, expected ${RETEX_VERSION#v}"
  fi

  REL="$HOME_DIR/$VERSION"
  MARK="$REL/.retex-installed"
  [ -e "$HOME_DIR" ] && [ ! -d "$HOME_DIR" ] && die "$HOME_DIR exists but is not a directory"
  [ -e "$BIN_DIR" ] && [ ! -d "$BIN_DIR" ] && die "$BIN_DIR exists but is not a directory"
  if [ -e "$REL" ]; then
    [ -d "$REL" ] && [ -f "$MARK" ] || die "$REL exists but was not installed by this installer; choose another RETEX_HOME"
  fi
  if [ -e "$HOME_DIR/current" ] || [ -L "$HOME_DIR/current" ]; then
    [ -L "$HOME_DIR/current" ] || die "$HOME_DIR/current exists but is not a retex installer link"
    case "$(readlink "$HOME_DIR/current")" in "$HOME_DIR"/*) ;; *) die "$HOME_DIR/current points outside $HOME_DIR" ;; esac
  fi
  if [ -e "$BIN_DIR/retex" ] || [ -L "$BIN_DIR/retex" ]; then
    [ -L "$BIN_DIR/retex" ] || die "$BIN_DIR/retex exists but was not installed by this installer; move it aside or set RETEX_BIN_DIR"
    case "$(readlink "$BIN_DIR/retex")" in
      "$HOME_DIR/current/retex"|"$HOME_DIR"/*/retex) ;;
      *) die "$BIN_DIR/retex points outside $HOME_DIR; move it aside or set RETEX_BIN_DIR" ;;
    esac
  fi

  mkdir -p "$HOME_DIR" "$BIN_DIR"
  chmod 700 "$HOME_DIR" 2>/dev/null || true
  if [ ! -d "$REL" ]; then
    say "Installing Retex $VERSION..."
    mkdir "$REL.tmp.$$"
    cp "$BIN" "$REL.tmp.$$/retex"
    chmod 755 "$REL.tmp.$$/retex"
    printf 'installed by retex install.sh\nversion=%s\nhome=%s\n' "$VERSION" "$HOME_DIR" > "$REL.tmp.$$/.retex-installed"
    mv "$REL.tmp.$$" "$REL"
  elif [ ! -f "$REL/retex" ]; then
    say "Restoring the binary in Retex $VERSION..."
    cp "$BIN" "$REL/retex"
    chmod 755 "$REL/retex"
  else
    say "Retex $VERSION is already installed; relinking."
  fi

  swap_link "$REL" "$HOME_DIR/current"
  # Symlink, not a shell wrapper: `retex update` resolves symlinks so it
  # replaces the real binary in the version folder and keeps the shim intact.
  swap_link "$HOME_DIR/current/retex" "$BIN_DIR/retex"

  say "Retex $VERSION installed ($BIN_DIR/retex -> $HOME_DIR/current/retex)."
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) say "Add $BIN_DIR to your PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;; esac
  say "In-app updates replace $REL/retex and keep a rollback at $REL/retex.previous."
}

main "$@"
