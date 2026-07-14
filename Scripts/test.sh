#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA_ROOT=${DERIVED_DATA_PATH:-"$ROOT_DIR/.build/DerivedData"}
UNSIGNED_DERIVED_DATA_PATH="$DERIVED_DATA_ROOT/UnsignedUnitTests"
SIGNED_DERIVED_DATA_PATH="$DERIVED_DATA_ROOT/SignedIntegrationTests"

xcodebuild \
    -project "$ROOT_DIR/Resizer.xcodeproj" \
    -scheme Resizer \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$UNSIGNED_DERIVED_DATA_PATH" \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:ResizerTests \
    -skip-testing:ResizerTests/HeadlessTranscodingIntegrationTests \
    test

exec xcodebuild \
    -project "$ROOT_DIR/Resizer.xcodeproj" \
    -scheme Resizer \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$SIGNED_DERIVED_DATA_PATH" \
    -parallel-testing-enabled NO \
    -only-testing:ResizerTests/HeadlessTranscodingIntegrationTests \
    test
