#!/usr/bin/env bash
#
# Build, sign (Developer ID + Hardened Runtime), notarize, staple, and package
# Beacon into a distributable .dmg that opens cleanly on other people's Macs.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
#   2. Notarization credentials stored in your keychain under a profile name:
#        xcrun notarytool store-credentials "beacon-notary" --apple-id "you@example.com"
#
# Usage:
#   bash scripts/release.sh [version]            # build + notarize + staple dmg
#   bash scripts/release.sh 0.1.0 --publish      # also create a GitHub Release
#
# Env overrides:
#   NOTARY_PROFILE   keychain profile name (default: beacon-notary)
#   SIGN_IDENTITY    full identity string (default: auto-detected Developer ID)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

APP_NAME="Beacon"
NOTARY_PROFILE="${NOTARY_PROFILE:-beacon-notary}"

# --- Args -------------------------------------------------------------------
VERSION="${1:-}"
PUBLISH="false"
for arg in "$@"; do
  [ "$arg" = "--publish" ] && PUBLISH="true"
done
if [ -z "$VERSION" ] || [ "$VERSION" = "--publish" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "0.1.0")"
fi

BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/$APP_NAME.app"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

# --- Locate signing identity -----------------------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  cat <<'EOF'
ERROR: No "Developer ID Application" certificate found in your keychain.

Create one via Xcode:
  Xcode > Settings > Accounts > (your team) > Manage Certificates
    > + > Developer ID Application

Then re-run this script.
EOF
  exit 1
fi
echo "==> Signing identity: $SIGN_IDENTITY"

# --- Verify notarization credentials exist ----------------------------------
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat <<EOF
ERROR: No notarization credentials found for profile "$NOTARY_PROFILE".

Store them once with:
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "you@example.com"

(You'll be prompted for your Team ID and an app-specific password from
 https://appleid.apple.com > Sign-In and Security > App-Specific Passwords.)
EOF
  exit 1
fi

# --- Build ------------------------------------------------------------------
echo "==> Building $APP_NAME $VERSION (release)..."
if ! swift build -c release; then
  echo "==> SwiftPM unavailable; compiling directly with swiftc..."
  mkdir -p "$BUILD_DIR"
  SOURCE_FILES=()
  while IFS= read -r file; do
    [[ -f "$file" ]] && SOURCE_FILES+=("$file")
  done < <(git ls-files --cached --others --exclude-standard \
    'Sources/Beacon/*.swift' 'Sources/Beacon/**/*.swift')

  xcrun swiftc -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    -O \
    "${SOURCE_FILES[@]}" \
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
    -lsqlite3
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" \
  "$APP_BUNDLE/Contents/Frameworks"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Vendor/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# --- Sign (Hardened Runtime + secure timestamp) -----------------------------
# Sparkle's nested XPC services and helpers must be signed inside-out before
# the framework, and the framework before the app (Sparkle sandboxing guide).
echo "==> Code signing with Hardened Runtime..."
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sign_if_present() {
  local path="$1"
  if [ -e "$path" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$path"
  fi
}
sign_if_present "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
sign_if_present "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
sign_if_present "$SPARKLE_FW/Versions/B/Autoupdate"
sign_if_present "$SPARKLE_FW/Versions/B/Updater.app"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
  "$SPARKLE_FW"
codesign --force --options runtime --timestamp \
  --entitlements "$ROOT/Resources/Beacon.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

mkdir -p "$DIST_DIR"

# --- Notarize the app -------------------------------------------------------
echo "==> Notarizing app (this can take a minute or two)..."
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling notarization ticket to the app..."
xcrun stapler staple "$APP_BUNDLE"

# --- Build DMG --------------------------------------------------------------
echo "==> Creating $DMG_PATH..."
STAGING="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING"

# --- Notarize + staple the DMG ---------------------------------------------
echo "==> Notarizing the DMG..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

# --- Verify Gatekeeper acceptance ------------------------------------------
# Note: a .dmg is not itself code-signed; its notarization ticket is stapled,
# so we validate the ticket here. (Gatekeeper assesses the app inside on open.)
echo "==> Verifying notarization ticket on the DMG..."
xcrun stapler validate "$DMG_PATH"
rm -f "$ZIP_PATH"

# --- Sparkle: sign the update and refresh the appcast ------------------------
# generate_appcast signs with the EdDSA key in the login keychain and MERGES
# new items into the existing appcast, so history is preserved. The appcast
# goes live when docs/ is pushed (GitHub Pages serves it at SUFeedURL).
echo "==> Updating Sparkle appcast (docs/appcast.xml)..."
APPCAST_STAGING="$(mktemp -d)"
cp "$DMG_PATH" "$APPCAST_STAGING/"
"$ROOT/Vendor/sparkle-tools/generate_appcast" \
  --download-url-prefix "https://github.com/claytonwendelwon/Mac-search/releases/download/v$VERSION/" \
  --link "https://beaconmac.com/" \
  -o "$ROOT/docs/appcast.xml" \
  "$APPCAST_STAGING"
rm -rf "$APPCAST_STAGING"
# The appcast (and site) go live on beaconmac.com via Cloudflare Pages.
echo "==> Deploying docs/ (site + appcast) to beaconmac.com..."
CLOUDFLARE_ACCOUNT_ID=305ab75281717568c5612a2abcbc696e \
  npx wrangler pages deploy "$ROOT/docs" --project-name beaconmac --commit-dirty=true

echo
echo "==> Done. Notarized, stapled disk image:"
echo "    $DMG_PATH"

# --- Optional: publish to GitHub Releases -----------------------------------
if [ "$PUBLISH" = "true" ]; then
  echo "==> Publishing GitHub Release v$VERSION..."
  NOTES_FILE="$(mktemp)"
  cat > "$NOTES_FILE" <<EOF
Beacon $VERSION — the fast, private macOS search that replaces Spotlight
and fixes Finder's blind spots.

## Install
1. Download \`$APP_NAME-$VERSION.dmg\` below and open it.
2. **Double-click Beacon.** It installs itself into Applications and
   relaunches from there. (Dragging to Applications works too.)
3. Press **Option + S** anywhere to search. Beacon lives in the menu bar.

Signed with a Developer ID and notarized by Apple — no security warnings.

## What's new in $VERSION
- **Automatic updates.** Beacon now updates itself (Sparkle). This is the
  last version you'll ever need to download by hand.
- **Launch at login.** Beacon survives reboots; toggle it from the
  menu-bar menu.
- **AI mode (new).** Describe what you're looking for in plain language and
  Beacon returns the actual files, messages, and emails — not a chat reply.
  Bring your own OpenAI, Claude, or Gemini key. Off by default; opt in from
  the AI toggle.
- **Full-disk file search.** Find files from any time, not just recent ones.
- **Free for now.** Beacon is currently free while we move payments to a new
  processor. The source stays public and free to build yourself.
- **Search you can trust.** Folder results refresh mid-session and deleted
  folders stop haunting results; videos found by type are no longer
  dropped (and TypeScript files no longer masquerade as videos); Docs,
  Photos, and Videos browsing skips repo junk instead of burying real
  files; the Screenshots filter honors your custom screenshot folder;
  Calendar finally shows recent and upcoming events.
- **Ranking that respects your query.** Exact-name matches rank first —
  across every source in the All view too.
- **Fresher data.** New texts, notes, browser history, and mail are
  findable mid-session without relaunching; contact-name search works the
  moment Contacts loads.
- **Much faster media browsing.** Scrolling Photos/Videos no longer
  restarts the search per page; thumbnails load in view order.
- **Fixes.** Quick Look no longer dismisses the panel; Cmd+C copies
  selected search text; fast typing can't open the wrong result; stores
  report real errors instead of wrongly demanding Full Disk Access.

## Full Disk Access (optional)
Messages, Notes, Mail, and Safari history need macOS **Full Disk Access**:
open a protected filter in Beacon, click **Open Settings**, flip the
toggle, then Quit & Reopen. File search needs no permissions at all.
EOF
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG_PATH" --clobber
  else
    gh release create "v$VERSION" "$DMG_PATH" \
      --title "Beacon $VERSION" --notes-file "$NOTES_FILE"
  fi
  rm -f "$NOTES_FILE"

  # Push the refreshed appcast so existing installs see the update.
  if ! git diff --quiet -- docs/appcast.xml; then
    echo "==> Committing and pushing the updated appcast..."
    git add docs/appcast.xml
    git commit -m "Publish appcast for $VERSION"
    git push origin main
  fi
  echo "==> Release published."
fi
