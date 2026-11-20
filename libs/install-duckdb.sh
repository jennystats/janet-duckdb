#!/bin/bash
# Install the pinned duckdb C library for the duckdb janet module
# (jennystats/duckdb.janet). Detects the platform, fetches the official
# duckdb shared-library release tarball, verifies sha256, extracts the
# library to ~/.local/lib/duckdb/. Idempotent; re-run to reinstall.
#
# Asset naming changed at duckdb 2.0: the release ships
# duckdb-shared-libs-<platform>.tar.gz (the 1.5 line shipped
# libduckdb-<platform>.zip). The library file names are unchanged.
#
# On macOS and Windows the module's default resolution looks for the
# linux-style soname, so set $DUCKDB_LIB to the installed file
# ($DEST/libduckdb.dylib on macOS, $DEST/duckdb.dll on Windows).
set -e
VERSION="2.0.1"
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
  linux-amd64)   SHA256="e25502612fed533a243b61f23a2a574daad030e7e88906222a5f0ab30d06769e" ;;
  linux-arm64)   SHA256="811e8b4d0226f5e531f583aadc798070ffb33b350e3823be563a2ebeb2c68593" ;;
  osx-universal) SHA256="9a4be5a2a31ad5bb8c92bf37f18d59b9c10a79b392d7848cabd6eb2e05837449" ;;
  windows-amd64) SHA256="d51f23831423b82418ee1d5bae324484f9fbe4a2c2424fa5b6be3392453c62ce" ;;
esac
URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/duckdb-shared-libs-${PLATFORM}.tar.gz"

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v tar >/dev/null || { echo "error: tar not found" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetching duckdb v$VERSION for $PLATFORM ..."
curl -fsSL -o "$TMP/libduckdb.tar.gz" "$URL"
echo "$SHA256  $TMP/libduckdb.tar.gz" | sha256sum -c -

mkdir -p "$DEST"
tar -xzf "$TMP/libduckdb.tar.gz" -C "$DEST" "$LIB"
echo "installed: $DEST/$LIB"
echo "usage    : (import jennystats/duckdb) - resolution: \$DUCKDB_LIB, then the linux default path"
