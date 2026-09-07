#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="$PWD/.build/semantic-tests"
mkdir -p "$BUILD"
xcrun swiftc -swift-version 5 -module-cache-path "$BUILD/module-cache" \
    Sources/Beacon/AIMediaKind.swift Sources/Beacon/SearchText.swift Sources/Beacon/DocumentText.swift \
    Sources/Beacon/CLIPTokenizer.swift Sources/Beacon/CLIPModel.swift Sources/Beacon/ImageSemanticIndex.swift \
    Sources/Beacon/PhotoStore.swift Sources/Beacon/JunkPath.swift Sources/Beacon/Log.swift \
    Sources/Beacon/AISearchTrace.swift Sources/Beacon/SpotlightFileSearch.swift Sources/Beacon/MailStore.swift \
    Tests/SemanticSearchChecks.swift -o "$BUILD/SemanticSearchChecks"
exec "$BUILD/SemanticSearchChecks" "$@"
