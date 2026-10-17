#!/bin/bash
# Install the pinned duckdb C library for the duckdb janet module
# (jennystats/duckdb.janet). Detects the platform, fetches the official
# duckdb release zip, verifies sha256, extracts the library to
# ~/.local/lib/duckdb/. Idempotent; re-run to reinstall.
#
# On macOS and Windows the module's default resolution looks for the
# linux-style soname, so set $DUCKDB_LIB to the installed file
# ($DEST/libduckdb.dylib on macOS, $DEST/duckdb.dll on Windows).
set -e
VERSION="1.5.6"
DEST="$HOME/.local/lib/duckdb"

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS/$ARCH" in
  Linux/x86_64)  PLATFORM="linux-amd64";   LIB="libduckdb.so" ;;
  Linux/aarch64) PLATFORM="linux-arm64";   LIB="libduckdb.so" ;;
  Darwin/arm64)  PLATFORM="osx-universal"; LIB="libduckdb.dylib" ;;
  Darwin/x86_64) PLATFORM="osx-universal"; LIB="libduckdb.dylib" ;;
  MINGW*/AMD64 | MSYS*/AMD64 | CYGWIN*/AMD64)
                 PLATFORM="windows-amd64"; LIB="duckdb.dll" ;;
  *)
    echo "error: unsupported platform $OS/$ARCH - fetch libduckdb v$VERSION for your platform from the duckdb releases" >&2
    exit 1 ;;
esac

case "$PLATFORM" in
  linux-amd64)   SHA256="b845005f5132a7d8180057c35e14a7626632258782f871a90861b19c1c03841b" ;;
  linux-arm64)   SHA256="b72ed9f05003f5e9d2015f7ceada6416b377d9dd33169cdde3c9e33897856eee" ;;
  osx-universal) SHA256="e0bc007d9b0094c0970ac1847a8601d10aad07cbd2910ce586ec810f77b638d6" ;;
  windows-amd64) SHA256="44cf59583f9951d2cb09b1bf115a63ecb2d8901e363903029d86c7d8683fe96a" ;;
esac
URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/libduckdb-${PLATFORM}.zip"

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v unzip >/dev/null || { echo "error: unzip not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching duckdb v$VERSION for $PLATFORM ..."
curl -fsSL -o "$TMP/libduckdb.zip" "$URL"
echo "$SHA256  $TMP/libduckdb.zip" | sha256sum -c -

mkdir -p "$DEST"
unzip -o -j "$TMP/libduckdb.zip" "$LIB" -d "$DEST"
echo "installed: $DEST/$LIB"
echo "usage    : (import jennystats/duckdb) - resolution: \$DUCKDB_LIB, then the linux default path"
