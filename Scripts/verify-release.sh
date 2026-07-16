#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=release-common.sh
. "$SCRIPT_DIR/release-common.sh"

release_initialize

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    release_fail "Usage: $0 <Resizer.dmg> [ffmpeg-source.tar.xz]"
fi

absolute_release_artifact() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$RELEASE_ROOT_DIR" "$1" ;;
    esac
}

DMG_PATH=$(absolute_release_artifact "$1")
release_require_direct_child_path "$DMG_PATH" "$RESIZER_RELEASE_ROOT"
case "$(basename "$DMG_PATH")" in
    *.dmg) ;;
    *) release_fail "The release artifact must use the .dmg extension" ;;
esac
release_require_regular_file "$DMG_PATH"

if [ "$#" -eq 2 ]; then
    SOURCE_ARCHIVE_PATH=$(absolute_release_artifact "$2")
else
    SOURCE_ARCHIVE_PATH="${DMG_PATH%.dmg}-ffmpeg-source.tar.xz"
fi
release_require_direct_child_path "$SOURCE_ARCHIVE_PATH" "$RESIZER_RELEASE_ROOT"
case "$(basename "$SOURCE_ARCHIVE_PATH")" in
    *-ffmpeg-source.tar.xz) ;;
    *) release_fail "The FFmpeg source bundle has an unexpected filename" ;;
esac
release_require_regular_file "$SOURCE_ARCHIVE_PATH"

for COMMAND in codesign cmp find hdiutil lipo nm otool plutil shasum spctl stat tar xcrun; do
    release_require_command "$COMMAND"
done

ALLOW_UNNOTARIZED=${RESIZER_ALLOW_UNNOTARIZED:-0}
case "$ALLOW_UNNOTARIZED" in
    0|1) ;;
    *) release_fail "RESIZER_ALLOW_UNNOTARIZED must be 0 or 1" ;;
esac
if [ "$ALLOW_UNNOTARIZED" = "0" ]; then
    release_validate_team_id "${DEVELOPMENT_TEAM:-}"
fi
release_invalidate_checksums

release_note "Verifying DMG structure and signature"
hdiutil verify "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
DMG_TEAM=
if [ "$ALLOW_UNNOTARIZED" = "0" ]; then
    release_require_developer_id_authority "$DMG_PATH"
    DMG_TEAM=$(release_codesign_team "$DMG_PATH")
    xcrun stapler validate "$DMG_PATH"
    spctl --assess \
        --type open \
        --context context:primary-signature \
        --verbose=2 \
        "$DMG_PATH"
else
    echo "warning: notarization and Gatekeeper checks are disabled; this artifact must not be distributed" >&2
fi

WORK_ROOT="$RESIZER_RELEASE_ROOT/.verify-$$"
MOUNT_POINT="$WORK_ROOT/mount"
ENTITLEMENTS_ROOT="$WORK_ROOT/entitlements"
SOURCE_EXTRACT_ROOT="$WORK_ROOT/source"
ATTACH_PLIST="$WORK_ROOT/attach.plist"
HDIUTIL_INFO_PLIST="$WORK_ROOT/hdiutil-info.plist"
ATTACH_ATTEMPTED=0
DEVICE_NODE=

device_from_entities() (
    PLIST_PATH=$1
    ENTITY_PREFIX=$2
    EXPECTED_MOUNT=$3
    ENTITY_COUNT=$(plutil -extract "$ENTITY_PREFIX" raw "$PLIST_PATH" 2>/dev/null) || exit 1
    ENTITY_INDEX=0
    while [ "$ENTITY_INDEX" -lt "$ENTITY_COUNT" ]; do
        ENTITY_MOUNT=$(
            plutil -extract "$ENTITY_PREFIX.$ENTITY_INDEX.mount-point" raw "$PLIST_PATH" 2>/dev/null || true
        )
        if [ "$ENTITY_MOUNT" = "$EXPECTED_MOUNT" ]; then
            ENTITY_DEVICE=$(
                plutil -extract "$ENTITY_PREFIX.$ENTITY_INDEX.dev-entry" raw "$PLIST_PATH" 2>/dev/null || true
            )
            if [ -n "$ENTITY_DEVICE" ]; then
                printf '%s\n' "$ENTITY_DEVICE"
                exit 0
            fi
        fi
        ENTITY_INDEX=$((ENTITY_INDEX + 1))
    done
    exit 1
)

device_from_hdiutil_info() (
    PLIST_PATH=$1
    EXPECTED_MOUNT=$2
    IMAGE_COUNT=$(plutil -extract images raw "$PLIST_PATH" 2>/dev/null) || exit 1
    IMAGE_INDEX=0
    while [ "$IMAGE_INDEX" -lt "$IMAGE_COUNT" ]; do
        if device_from_entities \
            "$PLIST_PATH" \
            "images.$IMAGE_INDEX.system-entities" \
            "$EXPECTED_MOUNT"; then
            exit 0
        fi
        IMAGE_INDEX=$((IMAGE_INDEX + 1))
    done
    exit 1
)

cleanup() {
    STATUS=$?
    trap - 0 1 2 15
    MOUNT_REMAINS=0
    if [ "$ATTACH_ATTEMPTED" -eq 1 ] && [ -z "$DEVICE_NODE" ] && [ -d "$WORK_ROOT" ]; then
        if hdiutil info -plist > "$HDIUTIL_INFO_PLIST" 2>/dev/null; then
            DEVICE_NODE=$(
                device_from_hdiutil_info "$HDIUTIL_INFO_PLIST" "$MOUNT_POINT" || true
            )
        else
            MOUNT_REMAINS=1
        fi
    fi
    if [ -n "$DEVICE_NODE" ]; then
        if ! hdiutil detach "$DEVICE_NODE" >/dev/null 2>&1; then
            MOUNT_REMAINS=1
            echo "warning: could not detach release verification DMG at $DEVICE_NODE" >&2
        fi
    fi
    if [ "$MOUNT_REMAINS" -eq 0 ] && [ -d "$WORK_ROOT" ] && [ ! -L "$WORK_ROOT" ]; then
        rm -rf "$WORK_ROOT"
    fi
    exit "$STATUS"
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

release_require_new_path "$WORK_ROOT"
mkdir -m 700 "$WORK_ROOT"
mkdir "$MOUNT_POINT" "$ENTITLEMENTS_ROOT" "$SOURCE_EXTRACT_ROOT"

release_note "Mounting DMG read-only"
ATTACH_ATTEMPTED=1
if ! hdiutil attach \
    -readonly \
    -nobrowse \
    -noautoopen \
    -plist \
    -mountpoint "$MOUNT_POINT" \
    "$DMG_PATH" > "$ATTACH_PLIST"; then
    release_fail "Could not attach the release DMG"
fi
DEVICE_NODE=$(device_from_entities "$ATTACH_PLIST" system-entities "$MOUNT_POINT" || true)
if [ -z "$DEVICE_NODE" ]; then
    release_fail "Could not identify the mounted DMG device"
fi

APP_PATH="$MOUNT_POINT/Resizer.app"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Resizer"
FFMPEG_EXECUTABLE="$APP_PATH/Contents/MacOS/ffmpeg"
FFPROBE_EXECUTABLE="$APP_PATH/Contents/MacOS/ffprobe"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
MOUNTED_SOURCE="$MOUNT_POINT/Open Source/$(basename "$SOURCE_ARCHIVE_PATH")"

release_require_real_directory "$APP_PATH"
release_require_regular_file "$INFO_PLIST"
release_require_regular_file "$MOUNTED_SOURCE"
if [ ! -L "$MOUNT_POINT/Applications" ] || \
   [ "$(readlink "$MOUNT_POINT/Applications")" != "/Applications" ]; then
    release_fail "DMG does not contain the expected Applications symlink"
fi
if ! cmp -s "$SOURCE_ARCHIVE_PATH" "$MOUNTED_SOURCE"; then
    release_fail "DMG contains a different FFmpeg source bundle"
fi

if [ "$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" != "com.example.Resizer" ]; then
    release_fail "Unexpected application bundle identifier"
fi
if [ "$(plutil -extract LSMinimumSystemVersion raw "$INFO_PLIST")" != "14.0" ]; then
    release_fail "Unexpected minimum macOS version"
fi
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")
APP_BUILD=$(plutil -extract CFBundleVersion raw "$INFO_PLIST")

for EXECUTABLE in "$APP_EXECUTABLE" "$FFMPEG_EXECUTABLE" "$FFPROBE_EXECUTABLE"; do
    release_require_universal_2 "$EXECUTABLE"
done
if [ "$(stat -f '%Lp' "$FFMPEG_EXECUTABLE")" != "755" ] || \
   [ "$(stat -f '%Lp' "$FFPROBE_EXECUTABLE")" != "755" ]; then
    release_fail "Bundled FFmpeg tools must have executable mode 0755"
fi

APP_TEAM=$DMG_TEAM
for SIGNED_ITEM in "$FFMPEG_EXECUTABLE" "$FFPROBE_EXECUTABLE" "$APP_PATH"; do
    if [ "$ALLOW_UNNOTARIZED" = "0" ]; then
        release_require_developer_id_signature "$SIGNED_ITEM"
        ITEM_TEAM=$(release_codesign_team "$SIGNED_ITEM")
        if [ -z "$APP_TEAM" ]; then
            APP_TEAM=$ITEM_TEAM
        elif [ "$ITEM_TEAM" != "$APP_TEAM" ]; then
            release_fail "Nested code uses a different Developer Team"
        fi
    else
        release_require_runtime_signature "$SIGNED_ITEM"
    fi
done

if ! release_codesign_report "$FFMPEG_EXECUTABLE" |
    grep -F 'Identifier=com.example.Resizer.ffmpeg' >/dev/null; then
    release_fail "Unexpected ffmpeg signing identifier"
fi
if ! release_codesign_report "$FFPROBE_EXECUTABLE" |
    grep -F 'Identifier=com.example.Resizer.ffprobe' >/dev/null; then
    release_fail "Unexpected ffprobe signing identifier"
fi

extract_entitlements() {
    codesign -d --entitlements :- "$1" > "$2" 2>/dev/null
    plutil -lint "$2" >/dev/null
}

require_true_entitlement() {
    if [ "$(/usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true)" != "true" ]; then
        release_fail "Required entitlement is missing: $2"
    fi
}

require_exact_entitlement_keys() {
    PLIST=$1
    ALLOWED_KEYS=$2
    ACTUAL_KEYS=$(
        /usr/libexec/PlistBuddy -c Print "$PLIST" |
            awk -F ' = ' '/ = / { key=$1; sub(/^[[:space:]]*/, "", key); print key }'
    )
    for KEY in $ACTUAL_KEYS; do
        case " $ALLOWED_KEYS " in
            *" $KEY "*) ;;
            *) release_fail "Unexpected entitlement: $KEY" ;;
        esac
    done
}

APP_ENTITLEMENTS="$ENTITLEMENTS_ROOT/app.plist"
FFMPEG_ENTITLEMENTS="$ENTITLEMENTS_ROOT/ffmpeg.plist"
FFPROBE_ENTITLEMENTS="$ENTITLEMENTS_ROOT/ffprobe.plist"
extract_entitlements "$APP_PATH" "$APP_ENTITLEMENTS"
extract_entitlements "$FFMPEG_EXECUTABLE" "$FFMPEG_ENTITLEMENTS"
extract_entitlements "$FFPROBE_EXECUTABLE" "$FFPROBE_ENTITLEMENTS"

require_true_entitlement "$APP_ENTITLEMENTS" com.apple.security.app-sandbox
require_true_entitlement "$APP_ENTITLEMENTS" com.apple.security.files.user-selected.read-write
require_exact_entitlement_keys \
    "$APP_ENTITLEMENTS" \
    "com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write"

for HELPER_ENTITLEMENTS in "$FFMPEG_ENTITLEMENTS" "$FFPROBE_ENTITLEMENTS"; do
    require_true_entitlement "$HELPER_ENTITLEMENTS" com.apple.security.app-sandbox
    require_true_entitlement "$HELPER_ENTITLEMENTS" com.apple.security.inherit
    require_exact_entitlement_keys \
        "$HELPER_ENTITLEMENTS" \
        "com.apple.security.app-sandbox com.apple.security.inherit"
done

verify_system_linkage() {
    if ! otool -L "$1" | awk '
        /^\t/ && $1 !~ /^\/(System\/Library|usr\/lib)\// { unexpected = 1 }
        END { exit unexpected }
    '; then
        release_fail "Unexpected non-system dynamic dependency: $1"
    fi
}
verify_system_linkage "$APP_EXECUTABLE"
verify_system_linkage "$FFMPEG_EXECUTABLE"
verify_system_linkage "$FFPROBE_EXECUTABLE"

if nm -m "$APP_EXECUTABLE" 2>/dev/null | grep -Eq '__llvm_prf_' || \
   otool -l "$APP_EXECUTABLE" | grep -F '__LLVM_COV' >/dev/null; then
    release_fail "Release executable contains code-coverage instrumentation"
fi

for RESOURCE in \
    THIRD_PARTY_NOTICES.md \
    COPYING.LGPLv2.1.txt \
    COPYING.LGPLv3.txt; do
    release_require_regular_file "$APP_PATH/Contents/Resources/$RESOURCE"
done
if ! grep -F 'GNU Lesser General' \
    "$APP_PATH/Contents/Resources/THIRD_PARTY_NOTICES.md" >/dev/null; then
    release_fail "Bundled third-party notice does not disclose the LGPL"
fi

if [ "$ALLOW_UNNOTARIZED" = "0" ]; then
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

# Helpers have the sandbox-inherit entitlement and intentionally are not
# launched from Terminal. Their functional smoke test must run through Resizer.

hdiutil detach "$DEVICE_NODE" >/dev/null
ATTACH_ATTEMPTED=0
DEVICE_NODE=

release_note "Verifying self-contained FFmpeg source bundle"
if tar -tJf "$SOURCE_ARCHIVE_PATH" | awk -F/ '
    /^\// { unsafe = 1 }
    { for (field = 1; field <= NF; field++) if ($field == "..") unsafe = 1 }
    END { exit unsafe }
'; then
    :
else
    release_fail "FFmpeg source archive contains an unsafe path"
fi
if ! tar -tvJf "$SOURCE_ARCHIVE_PATH" | awk '
    substr($1, 1, 1) != "-" && substr($1, 1, 1) != "d" { unsafe = 1 }
    END { exit unsafe }
'; then
    release_fail "FFmpeg source archive contains a link or special file"
fi
tar -xJf "$SOURCE_ARCHIVE_PATH" -C "$SOURCE_EXTRACT_ROOT"
SOURCE_MANIFESTS=$(find "$SOURCE_EXTRACT_ROOT" -name SOURCE_SHA256SUMS -type f -print)
if [ "$(printf '%s\n' "$SOURCE_MANIFESTS" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]; then
    release_fail "FFmpeg source archive must contain exactly one checksum manifest"
fi
SOURCE_PACKAGE_ROOT=$(dirname "$SOURCE_MANIFESTS")
(
    cd "$SOURCE_PACKAGE_ROOT"
    shasum -a 256 -c SOURCE_SHA256SUMS
)
release_require_corresponding_source_files "$SOURCE_PACKAGE_ROOT"
release_verify_ffmpeg_source_pins "$SOURCE_PACKAGE_ROOT"

if [ "$ALLOW_UNNOTARIZED" = "0" ]; then
    CHECKSUM_MANIFEST=$(release_write_checksums "$DMG_PATH" "$SOURCE_ARCHIVE_PATH")
    release_note "Final post-stapling checksums: $CHECKSUM_MANIFEST"
else
    echo "warning: final SHA256SUMS was not written for an unnotarized artifact" >&2
fi

release_note "Release verification passed for Resizer $APP_VERSION ($APP_BUILD)"
echo "Manual gate remaining: install the app and smoke-test H.264 and HEVC through the sandboxed UI."
