#!/bin/sh
# Assemble the downloadable release directory from already built assets:
#   RETEX_ASSET_SOURCE=<dir> scripts/build-release.sh [out-dir]
#
# The signed macOS archive and Linux binaries are built by scripts/release.sh;
# this helper only stages those assets together with install.sh and regenerates
# SHA256SUMS, so the installer and the binaries always ship as one verified
# batch. No signing identity, notary profile or token is read or stored here.
set -eu
cd "$(dirname "$0")/.."
SRC="${RETEX_ASSET_SOURCE:-release}"
OUT="${1:-dist/release}"
die() { printf 'build-release: %s\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "asset source directory not found: $SRC (set RETEX_ASSET_SOURCE)"
[ -f scripts/install.sh ] || die "scripts/install.sh is missing"

ROOT=$(pwd -P)
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
OUT=${OUT%/}
case "$OUT" in */..|*/../*|*/.|*/./*) die "out directory must not contain . or .." ;; esac
case "$OUT" in "$ROOT"/dist/?*) ;; *) die "out directory must be a non-empty path under $ROOT/dist" ;; esac
case "$(cd "$SRC" && pwd -P)/" in "$OUT"/*) die "out directory must not contain the asset source" ;; esac
rm -rf "$OUT"; mkdir -p "$OUT"
for asset in retex-universal.zip retex-linux-aarch64.tar.xz retex-linux-aarch64.tar.gz \
             retex-linux-x86_64.tar.xz retex-linux-x86_64.tar.gz retex-windows-x86_64.zip; do
  if [ -f "$SRC/$asset" ]; then cp "$SRC/$asset" "$OUT/$asset"; fi
done
[ "$(find "$OUT" -maxdepth 1 -name 'retex-*' -type f | wc -l | tr -d ' ')" -gt 0 ] || die "no retex binary assets in $SRC"
cp scripts/install.sh "$OUT/install.sh"
[ ! -f scripts/install.ps1 ] || cp scripts/install.ps1 "$OUT/install.ps1"

if command -v sha256sum >/dev/null 2>&1; then sum() { (cd "$OUT" && sha256sum "$@"); }
else sum() { (cd "$OUT" && shasum -a 256 "$@"); }; fi
assets=$(cd "$OUT" && ls -1 | LC_ALL=C sort)
# shellcheck disable=SC2086
sum $assets > "$OUT/SHA256SUMS"
echo "built $OUT from $SRC"
ls -l "$OUT"
