#!/usr/bin/env bash
# Build an isolated preview without replacing the installed Beacon app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d Resources/MobileCLIPImage.mlmodelc || ! -d Resources/MobileCLIPText.mlmodelc || ! -f Resources/bpe_simple_vocab_16e6.txt ]]; then
  python3 scripts/prepare-models.py
fi
swift build "$@"
PREVIEW_APP="${BEACON_PREVIEW_BUNDLE:-$PWD/dist/Beacon-Preview.app}"
mkdir -p "$PREVIEW_APP/Contents/MacOS" "$PREVIEW_APP/Contents/Resources" "$PREVIEW_APP/Contents/Frameworks"
cp .build/debug/Beacon "$PREVIEW_APP/Contents/MacOS/Beacon"
cp Resources/Info.plist "$PREVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.beacon.search.preview' "$PREVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Beacon Preview' "$PREVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Beacon Preview' "$PREVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :BeaconDevelopmentPreview bool true' "$PREVIEW_APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$PREVIEW_APP/Contents/Resources/"
for item in MobileCLIPImage.mlmodelc MobileCLIPText.mlmodelc bpe_simple_vocab_16e6.txt MobileCLIP-LICENSE.txt CLIP-TOKENIZER-LICENSE.txt; do
  ditto "Resources/$item" "$PREVIEW_APP/Contents/Resources/$item"
done
ditto Vendor/Sparkle.framework "$PREVIEW_APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$PREVIEW_APP/Contents/Frameworks/Sparkle.framework"
codesign --force --entitlements Resources/Beacon.entitlements --sign - "$PREVIEW_APP"
codesign --verify --strict "$PREVIEW_APP"
printf 'Preview ready: %s\n' "$PREVIEW_APP"
