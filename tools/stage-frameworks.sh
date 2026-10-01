#!/bin/bash
# Stage the WebRTC xcframework's macOS slice next to the built binary.
#
# SwiftPM resolves a binaryTarget into .build/artifacts/ and links against it,
# but does NOT copy the framework anywhere the product can find at run time, so
# the app dies at launch with:
#
#   dyld: Library not loaded: @rpath/WebRTC.framework/WebRTC
#
# `swift run` does not paper over this either. This copies the slice into
# <triple>/debug/Frameworks, which the @executable_path/Frameworks rpath in
# Package.swift then resolves.
set -euo pipefail
cd "$(dirname "$0")/.."

# Find the resolved macOS slice.
SLICE="$(find .build/artifacts -type d -name 'macos-*' -path '*WebRTC.xcframework*' 2>/dev/null | head -1)"
if [ -z "$SLICE" ]; then
  echo "error: no WebRTC macOS slice in .build/artifacts — run 'swift package resolve' first" >&2
  exit 1
fi
FW="$SLICE/WebRTC.framework"

# Find the directory holding the built product. SwiftPM's exact layout varies
# by version and toolchain (Products/Debug vs <triple>/debug), so locate the
# executable itself rather than guessing the path.
EXE="$(find .build -type f -name OpenDisplayBridge -perm -u+x 2>/dev/null | head -1)"
if [ -z "$EXE" ]; then
  echo "error: built executable not found under .build — run 'swift build' first" >&2
  exit 1
fi
BIN_DIR="$(dirname "$EXE")"

DEST="$BIN_DIR/Frameworks"
mkdir -p "$DEST"
# Replace rather than merge, so a version bump cannot leave a stale slice.
rm -rf "$DEST/WebRTC.framework"
cp -R "$FW" "$DEST/"

# A framework copied out of an xcframework has no symlinked Versions layout on
# some tools; verify the binary the dyld will actually load.
if [ ! -f "$DEST/WebRTC.framework/WebRTC" ]; then
  MAIN="$DEST/WebRTC.framework/Versions/A/WebRTC"
  if [ -f "$MAIN" ]; then
    ln -sf Versions/Current/WebRTC "$DEST/WebRTC.framework/WebRTC"
  else
    echo "error: staged framework has no loadable binary" >&2
    exit 1
  fi
fi

echo "staged $(basename "$FW") -> $DEST"
