#!/bin/zsh
# Retex release builder. Environment-driven; no personal defaults.
#
# Required:
#   RETEX_VERSION            stable semver matching AppVersion.swift
# Optional:
#   RETEX_SIGNING_IDENTITY   macOS codesign identity (default: ad-hoc "-")
#   NOTARY_PROFILE           notarytool Keychain profile for the macOS archive
#   RETEX_LINUX_SDK          installed Swift static Linux SDK ID
#   RETEX_LINUX_SWIFT        Swift executable matching RETEX_LINUX_SDK (auto-detected on macOS)
#   RETEX_LLVM_STRIP         LLVM strip executable for Linux ELF binaries
#
# The official static SDK currently omits target-named compiler-rt symlinks;
# this script repairs those links inside the user-owned SDK before building.
#   RETEX_WINDOWS_BINARY     verified Windows retex.exe built on Windows
#   RETEX_OUT                output directory (default: ./release)
set -euo pipefail

VERSION="${RETEX_VERSION:?Set RETEX_VERSION (for example 0.8.0)}"
IDENTITY="${RETEX_SIGNING_IDENTITY:--}"
LINUX_SDK="${RETEX_LINUX_SDK:-swift-6.3.3-RELEASE_static-linux-0.1.0}"
SDK_SWIFT_VERSION="${LINUX_SDK#swift-}"
SDK_SWIFT_VERSION="${SDK_SWIFT_VERSION%%-RELEASE*}"
DEFAULT_LINUX_SWIFT="$HOME/Library/Developer/Toolchains/swift-$SDK_SWIFT_VERSION-RELEASE.xctoolchain/usr/bin/swift"
if [[ -n "${RETEX_LINUX_SWIFT:-}" ]]; then
  LINUX_SWIFT="$RETEX_LINUX_SWIFT"
elif [[ -x "$DEFAULT_LINUX_SWIFT" ]]; then
  LINUX_SWIFT="$DEFAULT_LINUX_SWIFT"
else
  LINUX_SWIFT="swift"
fi
LLVM_STRIP="${RETEX_LLVM_STRIP:-llvm-strip}"
OUT="${RETEX_OUT:-release}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.release-build"
cd "$ROOT"

stage_support() {
  local destination="$1"
  mkdir -p "$destination/deploy/readonly-mcp"
  cp README.md LICENSE "$destination/"
  cp deploy/readonly-mcp/{Dockerfile,gateway.py,refresh_vault.py,validate_vault.py,verify_fleet.py} \
    "$destination/deploy/readonly-mcp/"
}

if [[ -n "$(git status --porcelain)" ]]; then
  echo "FAIL: repository is not clean"; exit 1
fi
command -v "$LLVM_STRIP" >/dev/null || { echo "FAIL: RETEX_LLVM_STRIP is unavailable"; exit 1; }
command -v "$LINUX_SWIFT" >/dev/null || { echo "FAIL: RETEX_LINUX_SWIFT is unavailable"; exit 1; }
if ! "$LINUX_SWIFT" --version | grep -q "Swift version $SDK_SWIFT_VERSION"; then
  echo "FAIL: RETEX_LINUX_SWIFT must match SDK Swift $SDK_SWIFT_VERSION"; exit 1
fi
if ! grep -q "static let version = \"$VERSION\"" Sources/RetexCLI/AppVersion.swift; then
  echo "FAIL: AppVersion.swift does not declare $VERSION"; exit 1
fi
if ! grep -q "^ARG RETEX_REF=v$VERSION$" deploy/readonly-mcp/Dockerfile; then
  echo "FAIL: hosted Dockerfile does not default to v$VERSION"; exit 1
fi

swift test >/dev/null
rm -rf "$BUILD"
mkdir -p "$BUILD/macos-arm64" "$BUILD/macos-x86_64" "$BUILD/bin"
swift build -c release --arch arm64 --product retex --scratch-path "$BUILD/macos-arm64" >/dev/null
swift build -c release --arch x86_64 --product retex --scratch-path "$BUILD/macos-x86_64" >/dev/null
lipo -create \
  "$BUILD/macos-arm64/release/retex" \
  "$BUILD/macos-x86_64/release/retex" \
  -output "$BUILD/bin/retex"
strip -x "$BUILD/bin/retex"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$BUILD/bin/retex"
codesign --verify --strict --verbose=1 "$BUILD/bin/retex"
stage_support "$BUILD/bin"
MAC_ARCHIVE="$OUT/retex-universal.zip"
(cd "$BUILD/bin" && zip -qry "$MAC_ARCHIVE" retex README.md LICENSE deploy)

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$MAC_ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
  STAGE="$BUILD/macos-stage"
  mkdir -p "$STAGE"
  ditto -x -k "$MAC_ARCHIVE" "$STAGE"
  xcrun stapler staple "$STAGE/retex" || echo "WARN: flat binary ticket verifies online"
  rm -f "$MAC_ARCHIVE"
  (cd "$STAGE" && zip -qry "$MAC_ARCHIVE" retex README.md LICENSE deploy)
fi

for spec in "aarch64:aarch64-swift-linux-musl" "x86_64:x86_64-swift-linux-musl"; do
  ARCH="${spec%%:*}"
  TRIPLE="${spec#*:}"
  CONFIG="$("$LINUX_SWIFT" sdk configure --show-configuration "$LINUX_SDK" "$TRIPLE")"
  SDK_ROOT="$(print -r -- "$CONFIG" | sed -n 's/^sdkRootPath: //p')"
  STATIC_ROOT="$(print -r -- "$CONFIG" | sed -n 's/^swiftStaticResourcesPath: //p')"
  [[ -d "$SDK_ROOT" && -d "$STATIC_ROOT" ]] || { echo "FAIL: incomplete $LINUX_SDK config for $TRIPLE"; exit 1; }
  BUILTINS_SOURCE="$SDK_ROOT/usr/lib/swift/clang/lib/linux/libclang_rt.builtins-$ARCH.a"
  SDK_BASE="${SDK_ROOT%/$ARCH}"
  [[ -f "$BUILTINS_SOURCE" ]] || { echo "FAIL: missing compiler runtime for $TRIPLE"; exit 1; }
  for resource_arch in aarch64 x86_64; do
    BUILTINS_DIR="$SDK_BASE/$resource_arch/usr/lib/swift_static/clang/lib/$TRIPLE"
    mkdir -p "$BUILTINS_DIR"
    ln -sfn "$BUILTINS_SOURCE" "$BUILTINS_DIR/libclang_rt.builtins.a"
  done

  SCRATCH="$BUILD/linux-$ARCH"
  "$LINUX_SWIFT" build -c release --swift-sdk "$LINUX_SDK" --triple "$TRIPLE" \
    -Xcc --sysroot -Xcc "$SDK_ROOT" \
    -Xswiftc -sdk -Xswiftc "$SDK_ROOT" \
    -Xswiftc -resource-dir -Xswiftc "$STATIC_ROOT" \
    --product retex --scratch-path "$SCRATCH" >/dev/null
  BINARY="$SCRATCH/$TRIPLE/release/retex"
  [[ -f "$BINARY" ]] || { echo "FAIL: missing $TRIPLE release binary"; exit 1; }
  STAGE="$BUILD/linux-$ARCH-stage"
  mkdir -p "$STAGE"
  cp "$BINARY" "$STAGE/retex"
  "$LLVM_STRIP" "$STAGE/retex"
  chmod 755 "$STAGE/retex"
  stage_support "$STAGE"
  COPYFILE_DISABLE=1 tar -czf "$OUT/retex-linux-$ARCH.tar.gz" -C "$STAGE" retex README.md LICENSE deploy
done

if [[ -n "${RETEX_WINDOWS_BINARY:-}" ]]; then
  [[ -f "$RETEX_WINDOWS_BINARY" ]] || { echo "FAIL: RETEX_WINDOWS_BINARY is not a file"; exit 1; }
  STAGE="$BUILD/windows-stage"
  mkdir -p "$STAGE"
  cp "$RETEX_WINDOWS_BINARY" "$STAGE/retex.exe"
  stage_support "$STAGE"
  (cd "$STAGE" && zip -qry "$OUT/retex-windows-x86_64.zip" retex.exe README.md LICENSE deploy)
fi

: > "$OUT/SHA256SUMS"
for asset in retex-universal.zip retex-linux-aarch64.tar.gz retex-linux-x86_64.tar.gz \
  ${RETEX_WINDOWS_BINARY:+retex-windows-x86_64.zip}; do
  hash="$(shasum -a 256 "$OUT/$asset" | awk '{print $1}')"
  print "$hash  $asset" >> "$OUT/SHA256SUMS"
done
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
echo "Retex $VERSION release assets: $OUT"
