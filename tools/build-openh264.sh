#!/bin/bash
# Build OpenH264 from source into a local prefix, with a deployment target of
# our choosing.
#
#   tools/build-openh264.sh [prefix]        # default: vendor/openh264
#   OD_DEPLOYMENT_TARGET=14.0 tools/build-openh264.sh
#
# Why not just use Homebrew
# -------------------------
# Homebrew's openh264 bottle is built against whatever macOS their CI runs, so
# 2.6.0 currently carries LC_BUILD_VERSION minos 26.0. A bundle that links it
# only launches on macOS 26, and the app's own plist then has to lie upward to
# match — which is how v0.3.0 ended up declaring it could not run on anything
# older than the deployment target it is compiled for.
#
# The codec is not the constraint; the bottle is. Building the same source with
# an explicit MACOSX_DEPLOYMENT_TARGET produces minos 13.0, and the result is
# byte-for-byte the same library otherwise. Verified by decoding a frame out of
# each build.
#
# Why a script and not a committed binary
# --------------------------------------
# A vendored dylib would be an opaque ~2 MB blob with no provenance in the diff,
# and it would need rebuilding per architecture. Fetching a pinned tarball and
# recording its checksum keeps the input reviewable and the output disposable.
#
# Licence: BSD-2-Clause, which permits redistribution in binary form PROVIDED the
# copyright notice and disclaimer are reproduced. `make-app.sh` copies LICENSE
# into the bundle for exactly that reason — do not drop that step.
#
# No nasm required: the x86 assembly in this project is not used on arm64, which
# compiles the NEON paths instead.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.6.0"
# sha256 of the auto-generated GitHub source tarball for tag v2.6.0.
#
# This is an integrity check, not an authenticity one: GitHub does not publish a
# digest for an auto-generated archive, so this pins *what we build* against
# corruption or tampering in transit, not against a compromised upstream tag.
# The authoritative artefact would be a signed release, which Cisco does not
# publish for the source.
SHA256="558544ad358283a7ab2930d69a9ceddf913f4a51ee9bf1bfb9e377322af81a69"
DEPLOYMENT_TARGET="${OD_DEPLOYMENT_TARGET:-13.0}"
PREFIX="${1:-vendor/openh264}"
ARCH="$(uname -m)"

# Absolute, always. The upstream Makefile uses PREFIX for two things at once: the
# destination of `make install`, and the -install_name baked into the dylib at
# link time. A relative PREFIX therefore (a) makes `install` write relative to
# the *source* directory, since the build runs with `make -C`, so the tree lands
# in the cache instead of the prefix, and (b) bakes a relative install_name into
# the library. Both were silent: the install reported success and the prefix
# stayed empty.
case "$PREFIX" in
  /*) ;;
  *) PREFIX="$PWD/$PREFIX" ;;
esac

# Kept out of the build tree so `make clean` and SwiftPM's own housekeeping have
# nothing to collide with, and so an interrupted build leaves a cache rather than
# a half-unpacked source tree.
CACHE="${OD_OPENH264_CACHE:-$HOME/.cache/openh264}"
TARBALL="$CACHE/openh264-$VERSION.tar.gz"
SRC="$CACHE/openh264-$VERSION-src"

mkdir -p "$CACHE" "$PREFIX"

if [ ! -f "$TARBALL" ]; then
  echo "==> fetching openh264 $VERSION"
  curl -fsSL -o "$TARBALL.tmp" \
    "https://github.com/cisco/openh264/archive/refs/tags/v$VERSION.tar.gz"
  mv "$TARBALL.tmp" "$TARBALL"
fi

echo "==> verifying checksum"
GOT="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA256" ]; then
  echo "error: checksum mismatch for $TARBALL" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $GOT" >&2
  echo "  refusing to build. Delete the file to re-fetch, or update SHA256 in" >&2
  echo "  this script if the upstream tag was re-cut deliberately." >&2
  exit 1
fi
echo "    sha256 ok"

if [ ! -d "$SRC" ]; then
  echo "==> unpacking"
  rm -rf "$SRC"
  mkdir -p "$SRC"
  tar xzf "$TARBALL" -C "$SRC" --strip-components=1
fi

echo "==> building (arch=$ARCH, deployment target=$DEPLOYMENT_TARGET)"
# PREFIX only affects where `make install` puts things; the dylib's own
# LC_ID_DYLIB is still hardcoded by the upstream Makefile, so it is rewritten
# below.
make -C "$SRC" -j"$(sysctl -n hw.ncpu)" \
  MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  ARCH="$ARCH" \
  PREFIX="$PREFIX" \
  >"$CACHE/build-$VERSION.log" 2>&1 || {
    echo "error: build failed; tail of $CACHE/build-$VERSION.log:" >&2
    tail -25 "$CACHE/build-$VERSION.log" >&2
    exit 1
  }

echo "==> installing to $PREFIX"
make -C "$SRC" install-shared PREFIX="$PREFIX" \
  >>"$CACHE/build-$VERSION.log" 2>&1 || {
    echo "error: install failed; tail of $CACHE/build-$VERSION.log:" >&2
    tail -25 "$CACHE/build-$VERSION.log" >&2
    exit 1
  }

# The upstream Makefile hardcodes -install_name /usr/local/lib/libopenh264.8.dylib
# regardless of PREFIX, which would bake this machine's layout into the shipped
# dylib. The app rewrites the *load command* to @rpath, but the dylib's own id
# should be relocatable too or anything linking against it records the wrong path.
DYLIB="$PREFIX/lib/libopenh264.8.dylib"
if [ -e "$DYLIB" ]; then
  install_name_tool -id "@rpath/libopenh264.8.dylib" "$DYLIB" 2>/dev/null || true
fi

# BSD-2-Clause requires the notice to travel with the binary.
cp -f "$SRC/LICENSE" "$PREFIX/LICENSE.openh264" 2>/dev/null || true

echo "==> verifying"
if [ ! -f "$PREFIX/include/wels/codec_api.h" ]; then
  echo "error: $PREFIX/include/wels/codec_api.h missing — Package.swift will not" >&2
  echo "       find this prefix and will fall back to Homebrew." >&2
  exit 1
fi
if [ ! -e "$DYLIB" ]; then
  echo "error: $DYLIB missing" >&2
  exit 1
fi

MINOS="$(otool -l "$DYLIB" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
if [ -z "$MINOS" ]; then
  MINOS="$(otool -l "$DYLIB" | awk '/LC_VERSION_MIN_MACOSX/{getline; getline; print $2; exit}')"
fi
echo "    deployment target: $MINOS"

if [ -n "$MINOS" ] && [ "$(printf '%s\n%s\n' "$DEPLOYMENT_TARGET" "$MINOS" | sort -V | head -1)" != "$DEPLOYMENT_TARGET" ]; then
  echo "    warning: the build asked for $DEPLOYMENT_TARGET but the dylib reports" >&2
  echo "             $MINOS. The SDK may have forced it up, which is what this" >&2
  echo "             whole script exists to avoid." >&2
fi

echo
echo "built:  $PREFIX (minos $MINOS)"
echo "use it: OD_OPENH264_PREFIX=$PREFIX swift build"
echo "        OD_OPENH264_PREFIX=$PREFIX swift test"
