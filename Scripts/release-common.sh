#!/bin/sh

# Shared fail-closed helpers for the direct Developer ID DMG workflow.
# This file is sourced by the release entry points and is not an entry point.

RESIZER_LIBX264_PROFILE_IDENTIFIER=libx264-8-and-10-bit-all-chroma-v1

release_fail() {
    echo "error: $1" >&2
    exit 1
}

release_note() {
    echo "==> $1"
}

release_require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        release_fail "Required command is unavailable: $1"
    fi
}

release_require_safe_absolute_path() {
    case "$1" in
        /*) ;;
        *) release_fail "Expected an absolute path: $1" ;;
    esac
    case "$1/" in
        *"/../"*|*"/./"*|*"//"*)
            release_fail "Path must not contain dot or empty components: $1"
            ;;
    esac
}

release_require_direct_child_path() {
    CHILD_PATH=$1
    EXPECTED_PARENT=$2
    release_require_safe_absolute_path "$CHILD_PATH"
    CHILD_PARENT=$(CDPATH= cd -- "$(dirname -- "$CHILD_PATH")" && pwd -P)
    if [ "$CHILD_PARENT" != "$EXPECTED_PARENT" ]; then
        release_fail "Path must be a direct child of $EXPECTED_PARENT: $CHILD_PATH"
    fi
}

release_validate_team_id() {
    if [ -z "$1" ]; then
        release_fail "DEVELOPMENT_TEAM is required for Developer ID builds"
    fi
    case "$1" in
        *[!A-Z0-9]*) release_fail "DEVELOPMENT_TEAM has an invalid format" ;;
    esac
    if [ "${#1}" -ne 10 ]; then
        release_fail "DEVELOPMENT_TEAM must be a 10-character Team ID"
    fi
}

release_initialize() {
    RELEASE_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    RELEASE_ROOT_DIR=$(CDPATH= cd -- "$RELEASE_SCRIPT_DIR/.." && pwd -P)
    RELEASE_BUILD_PARENT="$RELEASE_ROOT_DIR/.build"

    case ${RESIZER_RELEASE_ROOT:-} in
        "") RESIZER_RELEASE_ROOT="$RELEASE_BUILD_PARENT/Release" ;;
        /*) ;;
        *) RESIZER_RELEASE_ROOT="$RELEASE_ROOT_DIR/${RESIZER_RELEASE_ROOT}" ;;
    esac

    release_require_safe_absolute_path "$RESIZER_RELEASE_ROOT"
    case "$RESIZER_RELEASE_ROOT" in
        "$RELEASE_BUILD_PARENT"/*) ;;
        *) release_fail "RESIZER_RELEASE_ROOT must stay below $RELEASE_BUILD_PARENT" ;;
    esac

    if [ -L "$RELEASE_BUILD_PARENT" ]; then
        release_fail "Refusing symlinked build directory: $RELEASE_BUILD_PARENT"
    fi
    if [ ! -e "$RELEASE_BUILD_PARENT" ]; then
        mkdir -m 700 "$RELEASE_BUILD_PARENT"
    fi
    if [ ! -d "$RELEASE_BUILD_PARENT" ]; then
        release_fail "Expected build directory: $RELEASE_BUILD_PARENT"
    fi
    if [ "$(stat -f '%u' "$RELEASE_BUILD_PARENT")" != "$(id -u)" ]; then
        release_fail "Build directory is not owned by the current user"
    fi
    release_require_direct_child_path "$RESIZER_RELEASE_ROOT" "$RELEASE_BUILD_PARENT"

    if [ -L "$RESIZER_RELEASE_ROOT" ]; then
        release_fail "Refusing symlinked release directory: $RESIZER_RELEASE_ROOT"
    fi
    if [ ! -e "$RESIZER_RELEASE_ROOT" ]; then
        mkdir -m 700 "$RESIZER_RELEASE_ROOT"
    fi
    if [ ! -d "$RESIZER_RELEASE_ROOT" ]; then
        release_fail "Expected release directory: $RESIZER_RELEASE_ROOT"
    fi
    if [ "$(stat -f '%u' "$RESIZER_RELEASE_ROOT")" != "$(id -u)" ]; then
        release_fail "Release directory is not owned by the current user"
    fi
    CANONICAL_RELEASE_ROOT=$(CDPATH= cd -- "$RESIZER_RELEASE_ROOT" && pwd -P)
    if [ "$CANONICAL_RELEASE_ROOT" != "$RESIZER_RELEASE_ROOT" ]; then
        release_fail "Release directory contains a symlink component: $RESIZER_RELEASE_ROOT"
    fi

    RESIZER_ARCHIVE_PATH=${RESIZER_ARCHIVE_PATH:-"$RESIZER_RELEASE_ROOT/Resizer.xcarchive"}
    release_require_direct_child_path "$RESIZER_ARCHIVE_PATH" "$RESIZER_RELEASE_ROOT"
}

release_require_regular_file() {
    if [ -L "$1" ] || [ ! -f "$1" ]; then
        release_fail "Expected a regular file, not a symlink: $1"
    fi
}

release_require_real_directory() {
    if [ -L "$1" ] || [ ! -d "$1" ]; then
        release_fail "Expected a real directory, not a symlink: $1"
    fi
}

release_require_new_path() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        release_fail "Refusing to replace existing release output: $1"
    fi
}

release_resolve_signing() {
    RESIZER_SIGNING_MODE=${RESIZER_SIGNING_MODE:-developer-id}

    case "$RESIZER_SIGNING_MODE" in
        developer-id)
            release_validate_team_id "${DEVELOPMENT_TEAM:-}"

            if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
                DEVELOPER_ID_APPLICATION=$(
                    security find-identity -v -p codesigning 2>/dev/null |
                        sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
                )
                IDENTITY_COUNT=$(
                    printf '%s\n' "$DEVELOPER_ID_APPLICATION" |
                        sed '/^$/d' |
                        wc -l |
                        tr -d ' '
                )
                if [ "$IDENTITY_COUNT" != "1" ]; then
                    release_fail "Set DEVELOPER_ID_APPLICATION to one installed Developer ID Application identity"
                fi
            fi
            case "$DEVELOPER_ID_APPLICATION" in
                "Developer ID Application:"*" ($DEVELOPMENT_TEAM)") ;;
                *) release_fail "Only a Developer ID Application identity is accepted" ;;
            esac
            IDENTITY_RECORD=$(
                security find-identity -v -p codesigning 2>/dev/null |
                    grep -F "\"$DEVELOPER_ID_APPLICATION\"" || true
            )
            if [ "$(printf '%s\n' "$IDENTITY_RECORD" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]; then
                release_fail "Developer ID Application identity is not available in Keychain"
            fi
            RESIZER_SIGNING_IDENTITY=$(printf '%s\n' "$IDENTITY_RECORD" | awk '{ print $2 }')
            case "$RESIZER_SIGNING_IDENTITY" in
                *[!A-Fa-f0-9]*) release_fail "Developer ID identity fingerprint is invalid" ;;
            esac
            if [ "${#RESIZER_SIGNING_IDENTITY}" -ne 40 ]; then
                release_fail "Developer ID identity fingerprint must contain 40 hex characters"
            fi
            ;;
        adhoc)
            if [ "${RESIZER_ALLOW_AD_HOC:-0}" != "1" ]; then
                release_fail "Ad-hoc mode requires RESIZER_ALLOW_AD_HOC=1 and must never be distributed"
            fi
            RESIZER_SIGNING_IDENTITY=-
            DEVELOPMENT_TEAM=
            ;;
        *)
            release_fail "RESIZER_SIGNING_MODE must be developer-id or adhoc"
            ;;
    esac
}

release_require_universal_2() {
    release_require_regular_file "$1"
    ARCHITECTURES=$(lipo -archs "$1")
    case " $ARCHITECTURES " in
        *" arm64 "*) ;;
        *) release_fail "Missing arm64 architecture: $1" ;;
    esac
    case " $ARCHITECTURES " in
        *" x86_64 "*) ;;
        *) release_fail "Missing x86_64 architecture: $1" ;;
    esac
    if [ "$(printf '%s\n' "$ARCHITECTURES" | wc -w | tr -d ' ')" != "2" ]; then
        release_fail "Unexpected extra architecture in $1: $ARCHITECTURES"
    fi
}

release_require_libx264_profile_marker() {
    PROFILE_BINARY=$1
    release_require_regular_file "$PROFILE_BINARY"
    for PROFILE_ARCHITECTURE in arm64 x86_64; do
        if ! strings -arch "$PROFILE_ARCHITECTURE" -- "$PROFILE_BINARY" |
            grep -F "8.1.2-$RESIZER_LIBX264_PROFILE_IDENTIFIER" >/dev/null; then
            release_fail "Bundled helper lacks the libx264 profile marker for $PROFILE_ARCHITECTURE: $PROFILE_BINARY"
        fi
    done
}

release_codesign_report() {
    codesign -dvvv "$1" 2>&1
}

release_codesign_team() {
    release_codesign_report "$1" | sed -n 's/^TeamIdentifier=//p'
}

release_require_runtime_signature() {
    codesign --verify --strict --all-architectures --verbose=2 "$1"
    if ! release_codesign_report "$1" | grep -Eq '^CodeDirectory .*flags=.*runtime'; then
        release_fail "Hardened Runtime signature is missing: $1"
    fi
}

release_require_developer_id_authority() {
    codesign --verify --strict --verbose=2 "$1"
    SIGNING_REPORT=$(release_codesign_report "$1")
    if ! printf '%s\n' "$SIGNING_REPORT" |
        grep -F "Authority=Developer ID Application:" >/dev/null; then
        release_fail "Developer ID Application signature is missing: $1"
    fi
    SIGNED_TEAM=$(printf '%s\n' "$SIGNING_REPORT" | sed -n 's/^TeamIdentifier=//p')
    if [ -z "$SIGNED_TEAM" ] || [ "$SIGNED_TEAM" = "not set" ]; then
        release_fail "Developer ID signature has no Team ID: $1"
    fi
    SIGNED_TIMESTAMP=$(printf '%s\n' "$SIGNING_REPORT" | sed -n 's/^Timestamp=//p')
    if [ -z "$SIGNED_TIMESTAMP" ] || [ "$SIGNED_TIMESTAMP" = "none" ]; then
        release_fail "Developer ID signature has no secure timestamp: $1"
    fi
    if [ -n "${DEVELOPMENT_TEAM:-}" ] && [ "$SIGNED_TEAM" != "$DEVELOPMENT_TEAM" ]; then
        release_fail "Developer ID signature uses unexpected Team ID: $1"
    fi
}

release_require_developer_id_signature() {
    release_require_runtime_signature "$1"
    release_require_developer_id_authority "$1"
}

release_invalidate_checksums() {
    CHECKSUM_MANIFEST="$RESIZER_RELEASE_ROOT/SHA256SUMS"
    if [ -L "$CHECKSUM_MANIFEST" ]; then
        release_fail "Refusing symlinked release checksum manifest"
    fi
    if [ -e "$CHECKSUM_MANIFEST" ]; then
        if [ ! -f "$CHECKSUM_MANIFEST" ]; then
            release_fail "Expected a regular checksum manifest: $CHECKSUM_MANIFEST"
        fi
        rm -f "$CHECKSUM_MANIFEST"
    fi
}

release_verify_checksum_entry() {
    CHECKSUM_FILE=$1
    CHECKSUM_NAME=$2
    CHECKSUM_TARGET=$3
    release_require_regular_file "$CHECKSUM_FILE"
    release_require_regular_file "$CHECKSUM_TARGET"
    EXPECTED_CHECKSUMS=$(awk -v name="$CHECKSUM_NAME" '$2 == name { print $1 }' "$CHECKSUM_FILE")
    if [ "$(printf '%s\n' "$EXPECTED_CHECKSUMS" | sed '/^$/d' | wc -l | tr -d ' ')" != "1" ]; then
        release_fail "Expected one pinned checksum for $CHECKSUM_NAME"
    fi
    case "$EXPECTED_CHECKSUMS" in
        *[!A-Fa-f0-9]*) release_fail "Pinned checksum is not hexadecimal: $CHECKSUM_NAME" ;;
    esac
    if [ "${#EXPECTED_CHECKSUMS}" -ne 64 ]; then
        release_fail "Pinned checksum must contain 64 hex characters: $CHECKSUM_NAME"
    fi
    ACTUAL_CHECKSUM=$(shasum -a 256 "$CHECKSUM_TARGET" | awk '{ print $1 }')
    if [ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUMS" ]; then
        release_fail "Pinned checksum mismatch: $CHECKSUM_TARGET"
    fi
}

release_require_no_xcode_user_data() {
    SOURCE_ROOT=$1
    SOURCE_PRIVATE_XCODE_DATA=$(find "$SOURCE_ROOT" -type d -name xcuserdata -print)
    if [ -n "$SOURCE_PRIVATE_XCODE_DATA" ]; then
        release_fail "Corresponding source must not contain Xcode xcuserdata"
    fi
}

release_require_corresponding_source_files() {
    SOURCE_ROOT=$1
    for SOURCE_RELATIVE_PATH in \
        LICENSE \
        COPYRIGHT \
        README.md \
        PLAN.md \
        AGENTS.md \
        THIRD_PARTY_NOTICES.md \
        docs/architecture.md \
        docs/RELEASING.md \
        docs/adr/0014-libx264-gpl-toolchain.md \
        docs/adr/0016-libx264-high-bit-depth-chroma.md \
        Resizer.xcodeproj/project.pbxproj \
        Resizer.xcodeproj/project.xcworkspace/contents.xcworkspacedata \
        Resizer/ResizerApp.swift \
        ResizerTests/Integration/HeadlessTranscodingIntegrationTests.swift \
        ResizerTests/Fixtures/Media/short-h264-aac.mp4 \
        Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz \
        Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz.asc \
        Vendor/FFmpeg/patches/0001-avformat-fd-accept-descriptor-in-url.patch \
        Vendor/FFmpeg/checksums/SHA256SUMS \
        Vendor/FFmpeg/README.md \
        Vendor/FFmpeg/sources/README.md \
        Vendor/FFmpeg/build-config/ffmpeg-buildconf.txt \
        Vendor/FFmpeg/build-config/ffmpeg-version.txt \
        Vendor/FFmpeg/build-config/ffprobe-version.txt \
        Vendor/FFmpeg/build-config/ffmpeg-wrapper-encode-smoke-arm64.txt \
        Vendor/FFmpeg/build-config/ffmpeg-wrapper-encode-smoke-x86_64.txt \
        Vendor/FFmpeg/build-config/libx264-profile.txt \
        Vendor/FFmpeg/build-config/runtime-license.txt \
        Vendor/FFmpeg/build-config/profile.txt \
        Vendor/FFmpeg/licenses/COPYING.GPLv2 \
        Vendor/FFmpeg/licenses/COPYING.LGPLv2.1 \
        Vendor/FFmpeg/licenses/COPYING.LGPLv3 \
        Vendor/FFmpeg/licenses/LICENSE.md \
        Scripts/build-ffmpeg.sh \
        Vendor/x264/sources/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz \
        Vendor/x264/checksums/SHA256SUMS \
        Vendor/x264/licenses/COPYING \
        Vendor/x264/patches/0001-reproducible-version-metadata.patch \
        Vendor/x264/tests/encode-smoke.c \
        Vendor/x264/README.md \
        Scripts/support/pkg-config-x264 \
        Configuration/FFmpegHelper.entitlements \
        Resizer/Resources/ThirdParty/THIRD_PARTY_NOTICES.md \
        Resizer/Resources/ThirdParty/COPYING.GPLv2.txt; do
        release_require_regular_file "$SOURCE_ROOT/$SOURCE_RELATIVE_PATH"
    done
}

release_verify_x264_source_pins() {
    SOURCE_ROOT=$1
    X264_CHECKSUMS="$SOURCE_ROOT/Vendor/x264/checksums/SHA256SUMS"
    release_verify_checksum_entry \
        "$X264_CHECKSUMS" \
        sources/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz \
        "$SOURCE_ROOT/Vendor/x264/sources/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.gz"
    release_verify_checksum_entry \
        "$X264_CHECKSUMS" \
        patches/0001-reproducible-version-metadata.patch \
        "$SOURCE_ROOT/Vendor/x264/patches/0001-reproducible-version-metadata.patch"
    release_verify_checksum_entry \
        "$X264_CHECKSUMS" \
        tests/encode-smoke.c \
        "$SOURCE_ROOT/Vendor/x264/tests/encode-smoke.c"
}

release_verify_libx264_profile() {
    SOURCE_ROOT=$1
    LIBX264_PROFILE="$SOURCE_ROOT/Vendor/FFmpeg/build-config/libx264-profile.txt"
    release_require_regular_file "$LIBX264_PROFILE"
    if ! awk '
        NR == 1 && $0 != "profile_identifier=libx264-8-and-10-bit-all-chroma-v1" { invalid = 1 }
        NR == 2 && $0 != "binary_version_marker=libx264-8-and-10-bit-all-chroma-v1" { invalid = 1 }
        NR == 3 && $0 != "bit_depths=8,10" { invalid = 1 }
        NR == 4 && $0 != "chroma_formats=420,422,444" { invalid = 1 }
        NR == 5 && $0 != "pixel_formats=yuv420p,yuv420p10le,yuv422p10le,yuv444p10le" { invalid = 1 }
        NR == 6 && $0 != "x264_api_smoke_matrix=arm64:8x400,8x420,8x422,8x444,10x400,10x420,10x422,10x444;x86_64:8x400,8x420,8x422,8x444,10x400,10x420,10x422,10x444" { invalid = 1 }
        NR == 7 && $0 != "ffmpeg_wrapper_smoke_matrix=arm64:yuv420p,yuv420p10le,yuv422p10le,yuv444p10le;x86_64:yuv420p,yuv420p10le,yuv422p10le,yuv444p10le" { invalid = 1 }
        NR == 8 && $0 != "ffmpeg_wrapper_smoke_fixture=ResizerTests/Fixtures/Media/short-h264-aac.mp4" { invalid = 1 }
        NR == 9 && $0 != "ffmpeg_wrapper_smoke_fixture_sha256=d36f4bd50eb9294bef46aec9de1b6182a32fc7980ad81b070b7b9ce44d91f1c1" { invalid = 1 }
        NR == 10 && $0 != "smoke_status=passed" { invalid = 1 }
        END { exit invalid || NR != 10 }
    ' "$LIBX264_PROFILE"; then
        release_fail "Bundled libx264 profile report does not match the required policy"
    fi

    for SMOKE_ARCHITECTURE in arm64 x86_64; do
        FFMPEG_WRAPPER_SMOKE="$SOURCE_ROOT/Vendor/FFmpeg/build-config/ffmpeg-wrapper-encode-smoke-$SMOKE_ARCHITECTURE.txt"
        release_require_regular_file "$FFMPEG_WRAPPER_SMOKE"
        if ! awk '
            NR == 1 && $0 != "fixture=ResizerTests/Fixtures/Media/short-h264-aac.mp4" { invalid = 1 }
            NR == 2 && $0 != "fixture_sha256=d36f4bd50eb9294bef46aec9de1b6182a32fc7980ad81b070b7b9ce44d91f1c1" { invalid = 1 }
            NR == 3 && $0 != "pixel_format=yuv420p codec_name=h264 output_pixel_format=yuv420p output_nonempty=yes" { invalid = 1 }
            NR == 4 && $0 != "pixel_format=yuv420p10le codec_name=h264 output_pixel_format=yuv420p10le output_nonempty=yes" { invalid = 1 }
            NR == 5 && $0 != "pixel_format=yuv422p10le codec_name=h264 output_pixel_format=yuv422p10le output_nonempty=yes" { invalid = 1 }
            NR == 6 && $0 != "pixel_format=yuv444p10le codec_name=h264 output_pixel_format=yuv444p10le output_nonempty=yes" { invalid = 1 }
            NR == 7 && $0 != "status=passed" { invalid = 1 }
            END { exit invalid || NR != 7 }
        ' "$FFMPEG_WRAPPER_SMOKE"; then
            release_fail "FFmpeg wrapper smoke report does not match the required policy: $SMOKE_ARCHITECTURE"
        fi
    done

    for PROFILE_TOOL in ffmpeg ffprobe; do
        VERSION_REPORT="$SOURCE_ROOT/Vendor/FFmpeg/build-config/$PROFILE_TOOL-version.txt"
        release_require_regular_file "$VERSION_REPORT"
        if ! awk \
            -v tool="$PROFILE_TOOL" \
            -v version="8.1.2-$RESIZER_LIBX264_PROFILE_IDENTIFIER" '
                NR == 1 { valid = ($1 == tool && $2 == "version" && $3 == version) }
                END { exit !valid }
            ' "$VERSION_REPORT"; then
            release_fail "Bundled $PROFILE_TOOL version report lacks the required profile marker"
        fi
    done

    FFMPEG_BUILDCONF="$SOURCE_ROOT/Vendor/FFmpeg/build-config/ffmpeg-buildconf.txt"
    release_require_regular_file "$FFMPEG_BUILDCONF"
    if ! grep -F \
        -- "--extra-version=$RESIZER_LIBX264_PROFILE_IDENTIFIER" \
        "$FFMPEG_BUILDCONF" >/dev/null; then
        release_fail "Bundled FFmpeg build configuration lacks the required profile marker"
    fi
}

release_verify_ffmpeg_source_pins() {
    SOURCE_ROOT=$1
    SOURCE_CHECKSUMS="$SOURCE_ROOT/Vendor/FFmpeg/checksums/SHA256SUMS"
    release_verify_checksum_entry \
        "$SOURCE_CHECKSUMS" \
        ffmpeg-8.1.2.tar.xz \
        "$SOURCE_ROOT/Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz"
    release_verify_checksum_entry \
        "$SOURCE_CHECKSUMS" \
        ffmpeg-8.1.2.tar.xz.asc \
        "$SOURCE_ROOT/Vendor/FFmpeg/sources/ffmpeg-8.1.2.tar.xz.asc"
    release_verify_checksum_entry \
        "$SOURCE_CHECKSUMS" \
        0001-avformat-fd-accept-descriptor-in-url.patch \
        "$SOURCE_ROOT/Vendor/FFmpeg/patches/0001-avformat-fd-accept-descriptor-in-url.patch"
    release_verify_checksum_entry \
        "$SOURCE_CHECKSUMS" \
        ResizerTests/Fixtures/Media/short-h264-aac.mp4 \
        "$SOURCE_ROOT/ResizerTests/Fixtures/Media/short-h264-aac.mp4"
    release_verify_libx264_profile "$SOURCE_ROOT"
}

release_verify_repository_ffmpeg_materials() {
    release_require_corresponding_source_files "$RELEASE_ROOT_DIR"
    release_verify_ffmpeg_source_pins "$RELEASE_ROOT_DIR"
    release_verify_x264_source_pins "$RELEASE_ROOT_DIR"
    BUILD_CHECKSUMS="$RELEASE_ROOT_DIR/Vendor/FFmpeg/checksums/BUILD_SHA256SUMS"
    release_require_regular_file "$BUILD_CHECKSUMS"
    (
        cd "$RELEASE_ROOT_DIR"
        shasum -a 256 -c Vendor/FFmpeg/checksums/BUILD_SHA256SUMS
    )
}

release_write_checksums() {
    CHECKSUM_MANIFEST="$RESIZER_RELEASE_ROOT/SHA256SUMS"
    CHECKSUM_TEMP="$RESIZER_RELEASE_ROOT/.SHA256SUMS.$$"
    release_require_new_path "$CHECKSUM_MANIFEST"
    release_require_new_path "$CHECKSUM_TEMP"
    : > "$CHECKSUM_TEMP"
    for ARTIFACT in "$@"; do
        release_require_regular_file "$ARTIFACT"
        release_require_direct_child_path "$ARTIFACT" "$RESIZER_RELEASE_ROOT"
        (
            cd "$RESIZER_RELEASE_ROOT"
            shasum -a 256 "$(basename "$ARTIFACT")"
        ) >> "$CHECKSUM_TEMP"
    done
    chmod 644 "$CHECKSUM_TEMP"
    mv "$CHECKSUM_TEMP" "$CHECKSUM_MANIFEST"
    echo "$CHECKSUM_MANIFEST"
}
