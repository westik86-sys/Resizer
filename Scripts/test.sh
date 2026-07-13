#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DERIVED_DATA_PATH=${DERIVED_DATA_PATH:-"$ROOT_DIR/.build/DerivedData"}

exec xcodebuild \
    -project "$ROOT_DIR/Resizer.xcodeproj" \
    -scheme Resizer \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:ResizerTests \
    CODE_SIGNING_ALLOWED=NO \
    test
