#!/bin/zsh
# Retex release builder. Environment-driven; no personal defaults.
#
# Required:
#   RETEX_VERSION            e.g. 0.2.0 (must match the tag being built)
# Optional:
#   RETEX_SIGNING_IDENTITY   codesign identity (default: sign for local distribution "-")
#   NOTARY_PROFILE           keychain profile created via
#                            `xcrun notarytool store-credentials <profile> ...`
#                            When set, the archive is notarized and stapled.
#   RETEX_OUT                output directory (default: ./release)
set -euo pipefail

VERSION="${RETEX_VERSION:?Set RETEX_VERSION (e.g. 0.2.0)}"
IDENTITY="${RETEX_SIGNING_IDENTITY:--}"
OUT="${RETEX_OUT:-release}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT"

echo "==> Clean tracked tree check"
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "FAIL: tracked tree is dirty"; exit 1
fi

echo "==> Tests"
swift test >/dev/null

echo "==> Universal build (arm64 + x86_64)"
BUILD="$ROOT/.release-build"
rm -rf "$BUILD"
mkdir -p "$BUILD/arm64" "$BUILD/x86_64"
swift build -c release --arch arm64 --product retex --scratch-path "$BUILD/arm64-scratch" >/dev/null
swift build -c release --arch x86_64 --product retex --scratch-path "$BUILD/x86_64-scratch" >/dev/null

BIN_DIR="$BUILD/bin"
mkdir -p "$BIN_DIR"
lipo -create \
  "$BUILD/arm64-scratch/release/retex" \
  "$BUILD/x86_64-scratch/release/retex" \
  -output "$BIN_DIR/retex"

echo "==> Codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --timestamp \
  "$BIN_DIR/retex"
codesign --verify --strict --verbose=1 "$BIN_DIR/retex"

echo "==> Package"
cp README.md LICENSE "$BIN_DIR/"
TARBALL="$OUT/retex-universal.zip"
(cd "$BIN_DIR" && zip -qry "$TARBALL" retex README.md LICENSE)

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarize + staple"
  xcrun notarytool submit "$TARBALL" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$TARBALL"
else
  echo "==> Skipping notarization (set NOTARY_PROFILE to enable)"
fi

# Checksums cover the final artifact (post-staple).
cat > "$OUT/SHA256SUMS" <<EOF
$(shasum -a 256 "$TARBALL" | awk '{print $1"  retex-universal.zip"}')
EOF

echo "==> Verify checksums"
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
if [[ -n "${NOTARY_PROFILE:-}" ]]; then xcrun stapler validate "$TARBALL"; fi
echo "==> Done: $OUT"
