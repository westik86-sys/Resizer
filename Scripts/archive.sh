#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=release-common.sh
. "$SCRIPT_DIR/release-common.sh"

release_initialize
release_resolve_signing

release_require_command xcodebuild
release_require_command codesign
release_require_command lipo
release_require_command shasum
release_require_new_path "$RESIZER_ARCHIVE_PATH"
release_invalidate_checksums
release_verify_repository_ffmpeg_materials

DERIVED_DATA_PATH="$RESIZER_RELEASE_ROOT/DerivedData"
if [ -L "$DERIVED_DATA_PATH" ]; then
    release_fail "Refusing symlinked Derived Data path: $DERIVED_DATA_PATH"
fi

release_note "Archiving Universal 2 Resizer ($RESIZER_SIGNING_MODE)"

if [ "$RESIZER_SIGNING_MODE" = "developer-id" ]; then
    xcodebuild \
        -project "$RELEASE_ROOT_DIR/Resizer.xcodeproj" \
        -scheme Resizer \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -archivePath "$RESIZER_ARCHIVE_PATH" \
        "ARCHS=arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        CLANG_ENABLE_CODE_COVERAGE=NO \
        CLANG_COVERAGE_MAPPING=NO \
        ENABLE_CODE_COVERAGE=NO \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        CODE_SIGN_IDENTITY="$RESIZER_SIGNING_IDENTITY" \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        OTHER_CODE_SIGN_FLAGS=--timestamp \
        archive
else
    xcodebuild \
        -project "$RELEASE_ROOT_DIR/Resizer.xcodeproj" \
        -scheme Resizer \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -archivePath "$RESIZER_ARCHIVE_PATH" \
        "ARCHS=arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        CLANG_ENABLE_CODE_COVERAGE=NO \
        CLANG_COVERAGE_MAPPING=NO \
        ENABLE_CODE_COVERAGE=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        archive
fi

ARCHIVED_APP="$RESIZER_ARCHIVE_PATH/Products/Applications/Resizer.app"
APP_EXECUTABLE="$ARCHIVED_APP/Contents/MacOS/Resizer"
FFMPEG_EXECUTABLE="$ARCHIVED_APP/Contents/MacOS/ffmpeg"
FFPROBE_EXECUTABLE="$ARCHIVED_APP/Contents/MacOS/ffprobe"

release_require_real_directory "$ARCHIVED_APP"
release_require_universal_2 "$APP_EXECUTABLE"
release_require_universal_2 "$FFMPEG_EXECUTABLE"
release_require_universal_2 "$FFPROBE_EXECUTABLE"

for SIGNED_ITEM in "$FFMPEG_EXECUTABLE" "$FFPROBE_EXECUTABLE" "$ARCHIVED_APP"; do
    if [ "$RESIZER_SIGNING_MODE" = "developer-id" ]; then
        release_require_developer_id_signature "$SIGNED_ITEM"
    else
        release_require_runtime_signature "$SIGNED_ITEM"
    fi
done

if nm -m "$APP_EXECUTABLE" 2>/dev/null | grep -Eq '__llvm_prf_' || \
   otool -l "$APP_EXECUTABLE" | grep -F '__LLVM_COV' >/dev/null; then
    release_fail "Release executable unexpectedly contains code-coverage instrumentation"
fi

ARCHIVE_INFO="$RESIZER_ARCHIVE_PATH/Info.plist"
release_require_regular_file "$ARCHIVE_INFO"

release_note "Archive created: $RESIZER_ARCHIVE_PATH"
if [ "$RESIZER_SIGNING_MODE" = "adhoc" ]; then
    echo "warning: this archive is ad hoc signed and must not be distributed" >&2
fi
