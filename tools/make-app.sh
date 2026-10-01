#!/bin/bash
# Assemble and sign a real .app bundle.
#
# Why this exists: the host gates VideoToolbox's hardware media path for
# unsigned, non-bundled processes. Run as a bare SwiftPM binary, H.264 encode
# returns kVTParameterErr (-12902) and decode callbacks never fire — which
# blocks the WebRTC fallback path entirely. A proper bundle with an Info.plist
# and a code signature is the primary fix, and is needed for Screen Recording
# TCC regardless.
#
# Ad-hoc signs when no Developer ID is present, which is enough to give the
# process a bundle identity. Pass a signing identity to use a real one:
#
#   tools/make-app.sh                 # ad-hoc
#   tools/make-app.sh "Developer ID Application: ..."
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
CONFIG="${OD_BUILD_CONFIG:-debug}"
APP="build/OpenDisplayBridge.app"
BUNDLE_ID="${OD_BUNDLE_ID:-dev.opendisplay.bridge}"

echo "==> building ($CONFIG)"
swift build -c "$CONFIG"
./tools/stage-frameworks.sh >/dev/null

# Locate the products directory for this configuration/triple. SwiftPM uses
# "debug"/"release" or "Debug"/"Release" depending on toolchain.
BIN="$(find .build -type f -name OpenDisplayBridge -perm -u+x -path "*Products*" \
        \( -path "*/$CONFIG/*" -o -path "*/$(printf '%s' "$CONFIG" | sed 's/^./\U&/')/*" \) \
        2>/dev/null | head -1)"
if [ -z "$BIN" ]; then
  BIN="$(find .build -type f -name OpenDisplayBridge -perm -u+x -path "*Products*" | head -1)"
fi
[ -n "$BIN" ] || { echo "error: built executable not found under .build" >&2; exit 1; }
BIN_DIR="$(dirname "$BIN")"
echo "    product: $BIN"

# Locate the SwiftPM resource bundle (holds Web/index.html + receiver.js).
RES="$(find .build -type d -name 'OpenDisplayBridge_OpenDisplayBridge.bundle' \
       -path "*Products*" 2>/dev/null | head -1)"
[ -n "$RES" ] || { echo "error: SwiftPM resource bundle not found" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/OpenDisplayBridge"
# Bundle.module resolves the resource bundle from Contents/Resources.
cp -R "$RES" "$APP/Contents/Resources/"
if [ -d "$BIN_DIR/Frameworks/WebRTC.framework" ]; then
  cp -R "$BIN_DIR/Frameworks/WebRTC.framework" "$APP/Contents/Frameworks/"
fi

# ---- OpenH264: bundle it and stop depending on the build machine's Homebrew ----
#
# Package.swift links OpenH264 by absolute path, so the binary as built carries
# /opt/homebrew/opt/openh264/lib/libopenh264.8.dylib as a load command AND as an
# rpath. Shipped as-is the app only launches on a machine with
# `brew install openh264` at exactly that path, and because that rpath is
# searched before @executable_path/Frameworks it would silently prefer the
# system copy over anything bundled even once one exists.
#
# So: copy the dylib in, repoint the load command at @rpath, and delete the
# absolute rpaths. @executable_path/Frameworks is already in the rpath list (it
# is how WebRTC.framework already resolves), so nothing needs adding.
OPENH264_BUNDLED=0
H264_NAME=""
OPENH264_SRC=""
# Resolve the dylib the way dyld will: read the load command for the name, then
# walk the rpath list until a candidate exists.
#
# This used to take the first `otool -L` line mentioning libopenh264 and treat it
# as a filesystem path, which only worked while that line was an absolute
# /opt/homebrew path. Now that the library is built into vendor/ and linked as
# @rpath, that line reads `@rpath/libopenh264.8.dylib` — which is not a path at
# all — so the copy silently did nothing and the script reported "OpenH264 not
# linked", producing a bundle with no decoder in it and no error. A build that
# quietly loses its software decoder is the exact failure this whole script
# exists to prevent, so the resolution is done properly.
H264_LOADCMD="$(otool -L "$APP/Contents/MacOS/OpenDisplayBridge" \
                | awk '/libopenh264/{print $1; exit}')"
if [ -n "$H264_LOADCMD" ]; then
  H264_NAME="$(basename "$H264_LOADCMD")"
  APPBIN="$APP/Contents/MacOS"
  # Absolute rpaths first, then @executable_path / @loader_path against the
  # bundle. Order does not matter much here because the target is found by
  # existence, not by priority.
  for RP in $(otool -l "$APP/Contents/MacOS/OpenDisplayBridge" \
                | awk '/cmd LC_RPATH/{getline; getline
                        sub(/^[[:space:]]*path[[:space:]]+/, "")
                        sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
                        print}'); do
    case "$RP" in
      @executable_path/*) CAND="$APPBIN/${RP#@executable_path/}" ;;
      @loader_path/*)     CAND="$APPBIN/${RP#@loader_path/}" ;;
      @*)                 continue ;;
      /*)                 CAND="$RP" ;;
      *)                  continue ;;
    esac
    if [ -f "$CAND/$H264_NAME" ]; then OPENH264_SRC="$CAND/$H264_NAME"; break; fi
  done
fi

if [ -n "$OPENH264_SRC" ] && [ -f "$OPENH264_SRC" ]; then
  echo "    bundling $H264_NAME from $OPENH264_SRC"
  cp -L "$OPENH264_SRC" "$APP/Contents/Frameworks/$H264_NAME"
  chmod 755 "$APP/Contents/Frameworks/$H264_NAME"

  # The binary's own LC_LOAD_DYLIB, plus the rpath that pointed at the build
  # tree. Both are already @rpath for a vendored build; the -change is a no-op
  # there and does the real work for a Homebrew-linked one.
  install_name_tool -change "$H264_LOADCMD" "@rpath/$H264_NAME" \
      "$APP/Contents/MacOS/OpenDisplayBridge" 2>/dev/null
  if [ "${OPENH264_SRC#/}" != "$OPENH264_SRC" ]; then
    install_name_tool -delete_rpath "$(dirname "$OPENH264_SRC")" \
        "$APP/Contents/MacOS/OpenDisplayBridge" 2>/dev/null || true
  fi

  # Drop every remaining rpath that points at this build machine: an absolute
  # path into .build is searched ahead of the bundle's own Frameworks and would
  # pull a stale framework off the machine that built this.
  #
  # The rule is "absolute, and not part of the OS or the toolchain", rather than
  # a list of known directories. An earlier version enumerated two paths and
  # guarded each with `[ -d ]`, which meant the one that mattered most — a
  # .build/PackageFrameworks that does not exist on this machine — was the one
  # deliberately left in. A path being absent is no reason to keep it.
  #
  # /usr/lib/swift and the Xcode toolchain path stay: they are how the Swift
  # runtime is found on a Mac older than the one that built this.
  KEEP_PREFIXES="/usr/lib /System /Applications/Xcode"
  # `-r`, not `-`: bash rejects `read - VAR` outright ("not a valid
  # identifier") and zsh accepts it, so the loop silently did nothing under the
  # script's own interpreter while looking correct when tested in a shell.
  while read -r RPATH_ENTRY || [ -n "$RPATH_ENTRY" ]; do
    case "$RPATH_ENTRY" in
      /*) ;;
      *) continue ;;                       # @-relative ones are fine
    esac
    for KEEP in $KEEP_PREFIXES; do
      case "$RPATH_ENTRY" in "$KEEP"*) continue 2 ;; esac
    done
    echo "    stripping build-machine rpath: $RPATH_ENTRY"
    install_name_tool -delete_rpath "$RPATH_ENTRY" \
        "$APP/Contents/MacOS/OpenDisplayBridge" 2>/dev/null || true
  done < <(otool -l "$APP/Contents/MacOS/OpenDisplayBridge" \
           | awk '/cmd LC_RPATH/ {
                    getline; getline
                    sub(/^[[:space:]]*path[[:space:]]+/, "")
                    sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
                    print
                  }')

  # Relocatable id, so nothing downstream records the build machine's path.
  install_name_tool -id "@rpath/$H264_NAME" \
      "$APP/Contents/Frameworks/$H264_NAME" 2>/dev/null

  # BSD-2-Clause permits redistributing the binary ONLY if the copyright notice
  # and disclaimer travel with it. A licence file in the source tree is not
  # enough: the recipient of a .app never sees the source tree, so the notice
  # has to be inside the bundle. This is a licence obligation, not a nicety.
  for LIC in "$PWD/vendor/openh264/LICENSE.openh264" \
             "$(brew --prefix openh264 2>/dev/null)/share/doc/openh264/LICENSE"; do
    if [ -f "$LIC" ]; then
      cp "$LIC" "$APP/Contents/Resources/LICENSE.openh264"
      echo "    licence: $(basename "$LIC")"
      break
    fi
  done
  if [ ! -f "$APP/Contents/Resources/LICENSE.openh264" ]; then
    echo "    WARNING: no OpenH264 licence found to bundle. BSD-2-Clause requires" >&2
    echo "    the notice to travel with the binary, so this build is not cleanly" >&2
    echo "    redistributable." >&2
  fi
  OPENH264_BUNDLED=1
else
  echo "    note: OpenH264 not linked (OD_NO_OPENH264?) — software H.264 decode"
  echo "          is unavailable in this build."
fi

# ---- icon ----
ICON="$APP/Contents/Resources/AppIcon.icns"
if [ -f "$ICON" ]; then
  echo "    icon: reusing $ICON"
else
  echo "==> generating icon"
  ./tools/make-icon.swift "$ICON" >/dev/null
fi

# ---- the real minimum macOS ----
#
# The plist used to claim 13.0, which is the deployment target Package.swift
# compiles for. But the bundled OpenH264 is a Homebrew bottle whose
# LC_BUILD_VERSION requires macOS 26, so a bundle claiming 13.0 does not fail
# politely on an older Mac — it dies in dyld with a missing-library error that
# says nothing about the real cause. Report the higher of the two.
MINOS="13.0"
if [ "$OPENH264_BUNDLED" = "1" ]; then
  H264_MINOS="$(otool -l "$APP/Contents/Frameworks/$H264_NAME" \
                 | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  if [ -n "$H264_MINOS" ]; then
    MINOS="$H264_MINOS"
    echo "    note: bundled OpenH264 requires macOS $H264_MINOS, so this build"
    echo "          will not run on anything older."
  fi
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                 <string>OpenDisplay Bridge</string>
  <key>CFBundleDisplayName</key>          <string>OpenDisplay Bridge</string>
  <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>            <string>OpenDisplayBridge</string>
  <key>CFBundleIconFile</key>             <string>AppIcon</string>
  <key>CFBundlePackageType</key>          <string>APPL</string>
  <key>CFBundleShortVersionString</key>   <string>0.1.0</string>
  <key>CFBundleVersion</key>              <string>1</string>
  <key>LSMinimumSystemVersion</key>       <string>$MINOS</string>
  <key>NSHighResolutionCapable</key>      <true/>
  <key>NSPrincipalClass</key>             <string>NSApplication</string>
  <!-- Required for the macOS Local Network prompt the LAN listener triggers. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>Discovers and serves OpenDisplay receivers on your local network.</string>
</dict>
</plist>
PLIST

echo "==> signing (identity: $IDENTITY)"
# Sign nested code first, then the bundle. --deep is avoided because it is
# deprecated and skips some nested signatures.
for NESTED in "$APP/Contents/Frameworks/WebRTC.framework" \
             "$APP/Contents/Frameworks/$H264_NAME"; do
  [ -e "$NESTED" ] || continue
  codesign --force --sign "$IDENTITY" --timestamp=none "$NESTED" 2>/dev/null || true
done
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true
echo
echo "built: $APP"
echo "run  : open '$APP'    (or execute it directly to keep stdout)"
