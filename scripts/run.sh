#!/usr/bin/env bash
#
# Build Beacon, assemble it into a proper .app bundle, ad-hoc sign it,
# and (re)launch it. Runs entirely from the terminal -- no Xcode GUI needed.
#
set -euo pipefail

# Resolve project root (parent of this scripts/ directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="Beacon"
CONFIG="${CONFIG:-release}"
BUILD_DIR="$ROOT/.build/$CONFIG"
# Install into /Applications so there's only ever ONE Beacon on the system.
# (Building a separate copy inside the project folder leads to launching a
# stale app from Spotlight/Dock while the dev copy lives elsewhere.)
APP_BUNDLE="/Applications/$APP_NAME.app"
if [[ ! -w "/Applications" || ( -e "$APP_BUNDLE" && ! -w "$APP_BUNDLE" ) ]]; then
  # A release installed by another macOS account may not be replaceable.
  # ~/Applications is treated as an installed location by SelfInstaller too.
  APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
fi

echo "==> Building $APP_NAME ($CONFIG)..."
if ! swift build -c "$CONFIG"; then
  # SwiftPM can be unavailable after a partial Command Line Tools update even
  # when swiftc and the macOS SDK are healthy. Keep local development unblocked
  # by compiling the dependency-free app directly with the same Swift mode.
  echo "==> SwiftPM unavailable; compiling directly with swiftc..."
  mkdir -p "$BUILD_DIR"
  SOURCE_FILES=()
  while IFS= read -r file; do
    [[ -f "$file" ]] && SOURCE_FILES+=("$file")
  done < <(git ls-files --cached --others --exclude-standard \
    'Sources/Beacon/*.swift' 'Sources/Beacon/**/*.swift')

  SWIFT_FLAGS=(-swift-version 5 -target "$(uname -m)-apple-macosx13.0")
  if [[ "$CONFIG" == "release" ]]; then
    SWIFT_FLAGS+=(-O)
  else
    SWIFT_FLAGS+=(-Onone -g)
  fi

  xcrun swiftc "${SWIFT_FLAGS[@]}" "${SOURCE_FILES[@]}" \
    -o "$BUILD_DIR/$APP_NAME" \
    -F "$ROOT/Vendor" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework EventKit \
    -framework QuartzCore \
    -framework UniformTypeIdentifiers \
    -framework QuickLook \
    -framework QuickLookThumbnailing \
    -framework CoreServices \
    -lsqlite3
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Vendor/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Prefer a stable local signing identity so macOS permissions (Full Disk
# Access, etc.) persist across rebuilds instead of resetting every time the
# ad-hoc signature changes. Create it once in Keychain Access:
#   Certificate Assistant -> Create a Certificate -> name "Beacon Local Dev",
#   type "Code Signing". Falls back to ad-hoc ("-") when it's absent.
SIGN_ID="-"; SIGN_NAME="ad-hoc"
for pref in "Developer ID Application" "Apple Development" "Beacon Local Dev"; do
  line="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "$pref" || true)"
  if [ -n "$line" ]; then
    SIGN_ID="$(echo "$line" | awk '{print $2}')"   # SHA-1 hash, robust
    SIGN_NAME="$pref"
    break
  fi
done
if [ "$SIGN_ID" = "-" ]; then
  echo "==> Ad-hoc signing (no stable identity; FDA won't persist across rebuilds)..."
else
  echo "==> Signing with '$SIGN_NAME' (permissions persist across rebuilds)..."
fi
codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" >/dev/null 2>&1 || true
codesign --force --deep --entitlements "$ROOT/Resources/Beacon.entitlements" --sign "$SIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 || \
  codesign --force --entitlements "$ROOT/Resources/Beacon.entitlements" --sign "$SIGN_ID" "$APP_BUNDLE"

echo "==> Relaunching..."
# Quit any running instance so the new build takes over.
osascript -e 'tell application "Beacon" to quit' >/dev/null 2>&1 || true
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 0.4
open "$APP_BUNDLE"

cat <<'EOF'

==> Beacon is running.
    - Look for the magnifying-glass icon in your menu bar.
    - Press  Option + S  anywhere to open the search bar.
    - Or click the menu-bar icon. Press  Esc  to dismiss it.

    Tip: For complete coverage of every folder on your Mac, grant
    Beacon Full Disk Access in:
      System Settings > Privacy & Security > Full Disk Access
    (Spotlight already indexes most user locations without it.)
EOF
