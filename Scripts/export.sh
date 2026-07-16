#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=release-common.sh
. "$SCRIPT_DIR/release-common.sh"

release_initialize
release_resolve_signing

for COMMAND in codesign ditto hdiutil lipo plutil shasum tar xcodebuild; do
    release_require_command "$COMMAND"
done

ARCHIVED_APP="$RESIZER_ARCHIVE_PATH/Products/Applications/Resizer.app"
INFO_PLIST="$ARCHIVED_APP/Contents/Info.plist"
release_require_real_directory "$ARCHIVED_APP"
release_require_regular_file "$INFO_PLIST"

APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")
APP_BUILD=$(plutil -extract CFBundleVersion raw "$INFO_PLIST")
case "$APP_VERSION-$APP_BUILD" in
    *[!A-Za-z0-9._-]*) release_fail "App version contains an unsafe artifact-name character" ;;
esac

ARTIFACT_STEM="Resizer-$APP_VERSION-$APP_BUILD"
DMG_PATH="$RESIZER_RELEASE_ROOT/$ARTIFACT_STEM.dmg"
SOURCE_ARCHIVE_PATH="$RESIZER_RELEASE_ROOT/$ARTIFACT_STEM-ffmpeg-source.tar.xz"
release_require_new_path "$DMG_PATH"
release_require_new_path "$SOURCE_ARCHIVE_PATH"
release_invalidate_checksums
release_verify_repository_ffmpeg_materials

WORK_ROOT="$RESIZER_RELEASE_ROOT/.export-$$"
DMG_TEMP="$RESIZER_RELEASE_ROOT/.$ARTIFACT_STEM.$$.dmg"
SOURCE_ARCHIVE_TEMP="$RESIZER_RELEASE_ROOT/.$ARTIFACT_STEM-source.$$.tar.xz"
EXPORT_OPTIONS="$RESIZER_RELEASE_ROOT/.ExportOptions.$$.plist"
PUBLISHED_SOURCE=0
PUBLISHED_DMG=0
PUBLISHING=0

cleanup() {
    STATUS=$?
    trap - 0 1 2 15
    if [ -d "$WORK_ROOT" ] && [ ! -L "$WORK_ROOT" ]; then
        rm -rf "$WORK_ROOT"
    fi
    rm -f "$DMG_TEMP" "$SOURCE_ARCHIVE_TEMP" "$EXPORT_OPTIONS"
    if [ "$STATUS" -ne 0 ] && [ "$PUBLISHING" -eq 1 ]; then
        if [ "$PUBLISHED_DMG" -eq 1 ]; then
            rm -f "$DMG_PATH"
        fi
        if [ "$PUBLISHED_SOURCE" -eq 1 ]; then
            rm -f "$SOURCE_ARCHIVE_PATH"
        fi
    fi
    exit "$STATUS"
}

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

release_require_new_path "$WORK_ROOT"
release_require_new_path "$DMG_TEMP"
release_require_new_path "$SOURCE_ARCHIVE_TEMP"
release_require_new_path "$EXPORT_OPTIONS"
mkdir -m 700 "$WORK_ROOT"

EXPORTED_ROOT="$WORK_ROOT/exported"
if [ "$RESIZER_SIGNING_MODE" = "developer-id" ]; then
    plutil -create xml1 "$EXPORT_OPTIONS"
    plutil -insert method -string developer-id "$EXPORT_OPTIONS"
    plutil -insert destination -string export "$EXPORT_OPTIONS"
    plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
    plutil -insert signingCertificate -string "$RESIZER_SIGNING_IDENTITY" "$EXPORT_OPTIONS"
    plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
    plutil -insert stripSwiftSymbols -bool true "$EXPORT_OPTIONS"
    plutil -insert manageAppVersionAndBuildNumber -bool false "$EXPORT_OPTIONS"

    release_note "Exporting the Developer ID archive"
    xcodebuild \
        -exportArchive \
        -archivePath "$RESIZER_ARCHIVE_PATH" \
        -exportPath "$EXPORTED_ROOT" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    EXPORTED_APP="$EXPORTED_ROOT/Resizer.app"
else
    mkdir -p "$EXPORTED_ROOT"
    EXPORTED_APP="$EXPORTED_ROOT/Resizer.app"
    ditto "$ARCHIVED_APP" "$EXPORTED_APP"
fi

release_require_real_directory "$EXPORTED_APP"
for SIGNED_ITEM in \
    "$EXPORTED_APP/Contents/MacOS/ffmpeg" \
    "$EXPORTED_APP/Contents/MacOS/ffprobe" \
    "$EXPORTED_APP"; do
    if [ "$RESIZER_SIGNING_MODE" = "developer-id" ]; then
        release_require_developer_id_signature "$SIGNED_ITEM"
    else
        release_require_runtime_signature "$SIGNED_ITEM"
    fi
done

SOURCE_PACKAGE_NAME="$ARTIFACT_STEM-ffmpeg-source"
SOURCE_PACKAGE_ROOT="$WORK_ROOT/$SOURCE_PACKAGE_NAME"
mkdir -p \
    "$SOURCE_PACKAGE_ROOT/Vendor/FFmpeg/bin" \
    "$SOURCE_PACKAGE_ROOT/Vendor/FFmpeg" \
    "$SOURCE_PACKAGE_ROOT/Scripts/support" \
    "$SOURCE_PACKAGE_ROOT/Configuration" \
    "$SOURCE_PACKAGE_ROOT/Resizer/Resources/ThirdParty"

for DIRECTORY in sources patches build-config licenses checksums; do
    ditto \
        "$RELEASE_ROOT_DIR/Vendor/FFmpeg/$DIRECTORY" \
        "$SOURCE_PACKAGE_ROOT/Vendor/FFmpeg/$DIRECTORY"
done
ditto \
    "$RELEASE_ROOT_DIR/Vendor/FFmpeg/README.md" \
    "$SOURCE_PACKAGE_ROOT/Vendor/FFmpeg/README.md"
ditto \
    "$RELEASE_ROOT_DIR/Scripts/build-ffmpeg.sh" \
    "$SOURCE_PACKAGE_ROOT/Scripts/build-ffmpeg.sh"
ditto \
    "$RELEASE_ROOT_DIR/Scripts/support/pkg-config-disabled" \
    "$SOURCE_PACKAGE_ROOT/Scripts/support/pkg-config-disabled"
ditto \
    "$RELEASE_ROOT_DIR/Configuration/FFmpegHelper.entitlements" \
    "$SOURCE_PACKAGE_ROOT/Configuration/FFmpegHelper.entitlements"
ditto \
    "$RELEASE_ROOT_DIR/Resizer/Resources/ThirdParty/THIRD_PARTY_NOTICES.md" \
    "$SOURCE_PACKAGE_ROOT/Resizer/Resources/ThirdParty/THIRD_PARTY_NOTICES.md"
chmod 755 \
    "$SOURCE_PACKAGE_ROOT/Scripts/build-ffmpeg.sh" \
    "$SOURCE_PACKAGE_ROOT/Scripts/support/pkg-config-disabled"

release_require_corresponding_source_files "$SOURCE_PACKAGE_ROOT"
release_verify_ffmpeg_source_pins "$SOURCE_PACKAGE_ROOT"

SOURCE_README="$SOURCE_PACKAGE_ROOT/README.md"
{
    echo "# Resizer FFmpeg corresponding source"
    echo
    echo "This bundle accompanies Resizer $APP_VERSION ($APP_BUILD)."
    echo "It contains the pinned FFmpeg 8.1.2 source, local patch, licenses,"
    echo "configuration reports, checksums, and the exact build script."
    echo
    echo "From this directory, run ./Scripts/build-ffmpeg.sh on a supported"
    echo "macOS/Xcode host. The script creates fresh arm64 and x86_64 builds."
} > "$SOURCE_README"

(
    cd "$SOURCE_PACKAGE_ROOT"
    find . -type f ! -name SOURCE_SHA256SUMS -print |
        LC_ALL=C sort |
        while IFS= read -r FILE; do
            shasum -a 256 "$FILE"
        done > SOURCE_SHA256SUMS
    shasum -a 256 -c SOURCE_SHA256SUMS
)

COPYFILE_DISABLE=1 tar \
    -cJf "$SOURCE_ARCHIVE_TEMP" \
    -C "$WORK_ROOT" \
    "$SOURCE_PACKAGE_NAME"

PAYLOAD_ROOT="$WORK_ROOT/dmg"
mkdir -p "$PAYLOAD_ROOT/Open Source"
ditto "$EXPORTED_APP" "$PAYLOAD_ROOT/Resizer.app"
ln -s /Applications "$PAYLOAD_ROOT/Applications"
ditto \
    "$SOURCE_ARCHIVE_TEMP" \
    "$PAYLOAD_ROOT/Open Source/$(basename "$SOURCE_ARCHIVE_PATH")"
ditto \
    "$RELEASE_ROOT_DIR/Resizer/Resources/ThirdParty/THIRD_PARTY_NOTICES.md" \
    "$PAYLOAD_ROOT/Open Source/THIRD_PARTY_NOTICES.md"
{
    echo "Resizer $APP_VERSION ($APP_BUILD)"
    echo
    echo "Drag Resizer.app to Applications."
    echo "Video processing stays local and original files are never overwritten."
    echo "Third-party notices and corresponding FFmpeg source are under Open Source."
} > "$PAYLOAD_ROOT/README.txt"

release_note "Creating compressed DMG"
hdiutil create \
    -srcfolder "$PAYLOAD_ROOT" \
    -volname "Resizer $APP_VERSION" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -nospotlight \
    "$DMG_TEMP"

if [ "$RESIZER_SIGNING_MODE" = "developer-id" ]; then
    codesign \
        --force \
        --sign "$RESIZER_SIGNING_IDENTITY" \
        --timestamp \
        "$DMG_TEMP"
else
    codesign --force --sign - "$DMG_TEMP"
fi

hdiutil verify "$DMG_TEMP"
codesign --verify --strict --verbose=2 "$DMG_TEMP"

PUBLISHING=1
mv "$SOURCE_ARCHIVE_TEMP" "$SOURCE_ARCHIVE_PATH"
PUBLISHED_SOURCE=1
mv "$DMG_TEMP" "$DMG_PATH"
PUBLISHED_DMG=1
PUBLISHING=0

release_note "DMG created: $DMG_PATH"
release_note "FFmpeg source bundle created: $SOURCE_ARCHIVE_PATH"
if [ "$RESIZER_SIGNING_MODE" = "adhoc" ]; then
    echo "warning: these ad-hoc artifacts must not be distributed" >&2
fi
echo "Run notarize.sh before generating final checksums."
