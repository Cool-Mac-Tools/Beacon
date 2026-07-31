#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if swift package dump-package >/dev/null 2>&1; then
  swift test
  exit
fi

echo "==> SwiftPM unavailable; running direct reliability checks..."
TEST_BUILD_DIR="$ROOT/.build/reliability-tests"
mkdir -p "$TEST_BUILD_DIR"
xcrun swiftc -swift-version 5 \
  Sources/Beacon/SearchText.swift \
  Sources/Beacon/SearchState.swift \
  Sources/Beacon/Log.swift \
  Sources/Beacon/AppStore.swift \
  Sources/Beacon/JunkPath.swift \
  Sources/Beacon/FolderStore.swift \
  Tests/FallbackSearchReliability.swift \
  -o "$TEST_BUILD_DIR/SearchReliabilityTests"
"$TEST_BUILD_DIR/SearchReliabilityTests"
