#!/bin/sh

set -eu

export LANG=C
export LC_ALL=C
export TZ=UTC
export ZERO_AR_DATE=1

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

VERSION=8.1.2
PROFILE_REVISION=12
DEPLOYMENT_TARGET=14.0
LIBX264_PROFILE_IDENTIFIER=libx264-8-and-10-bit-all-chroma-v1
ARCHIVE_NAME="ffmpeg-$VERSION.tar.xz"
ARCHIVE="$ROOT_DIR/Vendor/FFmpeg/sources/$ARCHIVE_NAME"
X264_REVISION=0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
X264_SHORT_REVISION=0480cb0
X264_BUILD=165
X264_REVISION_NUMBER=3223
X264_ARCHIVE_NAME="x264-$X264_REVISION.tar.gz"
X264_ARCHIVE="$ROOT_DIR/Vendor/x264/sources/$X264_ARCHIVE_NAME"
X264_CHECKSUMS="$ROOT_DIR/Vendor/x264/checksums/SHA256SUMS"
X264_PATCH_NAME=0001-reproducible-version-metadata.patch
X264_PATCH_FILE="$ROOT_DIR/Vendor/x264/patches/$X264_PATCH_NAME"
X264_SMOKE_NAME=tests/encode-smoke.c
X264_SMOKE_FILE="$ROOT_DIR/Vendor/x264/$X264_SMOKE_NAME"
FFMPEG_WRAPPER_SMOKE_NAME=ResizerTests/Fixtures/Media/short-h264-aac.mp4
FFMPEG_WRAPPER_SMOKE_FILE="$ROOT_DIR/$FFMPEG_WRAPPER_SMOKE_NAME"
PATCH_NAME="0001-avformat-fd-accept-descriptor-in-url.patch"
PATCH_FILE="$ROOT_DIR/Vendor/FFmpeg/patches/$PATCH_NAME"
PATCHED_FILE_TARGET="libavformat/file.c"
PATCHED_FILE_SHA256=a70cd7c73aede2e8af12e8208fc6aa520307310c5b1766ce538042481628b56a
PATCHED_DOC_TARGET="doc/protocols.texi"
PATCHED_DOC_SHA256=3605ab85752fdd25b55a5803fc8dbe0974dbfa94923d904b97486f5df6ce650e
PROFILE_SHA256=0db3e006e54fcf13da93b8a08895ad513d23e53a34797e13ef997bd38734f714
CHECKSUM_DIR="$ROOT_DIR/Vendor/FFmpeg/checksums"
CHECKSUMS="$CHECKSUM_DIR/SHA256SUMS"
BUILD_CHECKSUMS="$CHECKSUM_DIR/BUILD_SHA256SUMS"

# FFmpeg records its configure arguments and some compiler source paths in the
# resulting binaries. Keep the build in a stable, non-user-specific location
# and use a virtual install prefix so a developer's home directory or checkout
# path can never become part of the distributed tools.
WORK_PARENT="/private/tmp/com.example.Resizer.ffmpeg-build"
WORK_ROOT="$WORK_PARENT/$VERSION-profile$PROFILE_REVISION"
MAPPED_BUILD_ROOT="/usr/src/resizer-ffmpeg/$VERSION-profile$PROFILE_REVISION"
VIRTUAL_PREFIX_ROOT="/opt/resizer-toolchain/ffmpeg/$VERSION-profile$PROFILE_REVISION"
SOURCE_DIR="$WORK_ROOT/source"
X264_SOURCE_DIR="$WORK_ROOT/x264-source"
STAGE_ROOT="$WORK_ROOT/staging"
STAGED_VENDOR_DIR="$STAGE_ROOT/Vendor/FFmpeg"
STAGED_OUTPUT_DIR="$STAGED_VENDOR_DIR/bin"
STAGED_REPORT_DIR="$STAGED_VENDOR_DIR/build-config"
STAGED_CHECKSUM_DIR="$STAGED_VENDOR_DIR/checksums"
STAGED_BUILD_CHECKSUMS="$STAGED_CHECKSUM_DIR/BUILD_SHA256SUMS"
VENDOR_DIR="$ROOT_DIR/Vendor/FFmpeg"
OUTPUT_DIR="$ROOT_DIR/Vendor/FFmpeg/bin"
REPORT_DIR="$ROOT_DIR/Vendor/FFmpeg/build-config"
PROFILE_SOURCE="$REPORT_DIR/profile.txt"
ENTITLEMENTS="$ROOT_DIR/Configuration/FFmpegHelper.entitlements"
PKG_CONFIG_SOURCE="$SCRIPT_DIR/support/pkg-config-x264"
PKG_CONFIG_X264="$WORK_ROOT/pkg-config-x264"
LOCK_DIR="$WORK_PARENT/.build-lock"

CURRENT_UID=$(id -u)
LOCK_HELD=0
PUBLISH_ACTIVE=0
PUBLISH_ROOT_CREATED=0
PUBLISH_ROOT="$VENDOR_DIR/.ffmpeg-publish-$$"
OLD_OUTPUT_DIR="$VENDOR_DIR/.bin.previous-$$"
OLD_REPORT_DIR="$VENDOR_DIR/.build-config.previous-$$"
OLD_BUILD_CHECKSUMS="$CHECKSUM_DIR/.BUILD_SHA256SUMS.previous-$$"

fail() {
    echo "$1" >&2
    exit 1
}

require_owned_directory() {
    DIRECTORY=$1
    EXPECTED_PATH=$2

    if [ -L "$DIRECTORY" ] || [ ! -d "$DIRECTORY" ]; then
        fail "Expected a real directory, not a symlink: $DIRECTORY"
    fi
    if [ "$(stat -f '%u' "$DIRECTORY")" != "$CURRENT_UID" ]; then
        fail "Directory is not owned by the current user: $DIRECTORY"
    fi

    ACTUAL_PATH=$(CDPATH= cd -- "$DIRECTORY" && pwd -P)
    if [ "$ACTUAL_PATH" != "$EXPECTED_PATH" ]; then
        fail "Directory resolves outside its expected path: $DIRECTORY"
    fi
}

rollback_publish() {
    if [ "$PUBLISH_ACTIVE" -ne 1 ]; then
        return
    fi

    if [ -d "$OLD_OUTPUT_DIR" ] && [ ! -L "$OLD_OUTPUT_DIR" ]; then
        if [ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ]; then
            rm -rf "$OUTPUT_DIR"
        fi
        mv "$OLD_OUTPUT_DIR" "$OUTPUT_DIR"
    fi
    if [ -d "$OLD_REPORT_DIR" ] && [ ! -L "$OLD_REPORT_DIR" ]; then
        if [ -d "$REPORT_DIR" ] && [ ! -L "$REPORT_DIR" ]; then
            rm -rf "$REPORT_DIR"
        fi
        mv "$OLD_REPORT_DIR" "$REPORT_DIR"
    fi
    if [ -f "$OLD_BUILD_CHECKSUMS" ] && [ ! -L "$OLD_BUILD_CHECKSUMS" ]; then
        rm -f "$BUILD_CHECKSUMS"
        mv "$OLD_BUILD_CHECKSUMS" "$BUILD_CHECKSUMS"
    fi
}

cleanup() {
    STATUS=$?
    trap - 0 1 2 15

    rollback_publish

    if [ "$PUBLISH_ROOT_CREATED" -eq 1 ] && [ -d "$PUBLISH_ROOT" ] && [ ! -L "$PUBLISH_ROOT" ]; then
        rm -rf "$PUBLISH_ROOT"
    fi
    if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi

    exit "$STATUS"
}

trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

require_owned_directory "$VENDOR_DIR" "$VENDOR_DIR"
require_owned_directory "$CHECKSUM_DIR" "$CHECKSUM_DIR"
if [ ! -f "$CHECKSUMS" ] || [ -L "$CHECKSUMS" ]; then
    fail "Expected a regular source checksum manifest: $CHECKSUMS"
fi
if [ ! -f "$X264_CHECKSUMS" ] || [ -L "$X264_CHECKSUMS" ]; then
    fail "Expected a regular x264 source checksum manifest: $X264_CHECKSUMS"
fi

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
CLANG=$(xcrun --sdk macosx --find clang)
AR=$(xcrun --sdk macosx --find ar)
RANLIB=$(xcrun --sdk macosx --find ranlib)
STRIP=$(xcrun --sdk macosx --find strip)
NM=$(xcrun --sdk macosx --find nm)
VTOOL=$(xcrun --sdk macosx --find vtool)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

if [ ! -f "$ARCHIVE" ]; then
    echo "Missing FFmpeg source archive: $ARCHIVE" >&2
    exit 1
fi
if [ ! -f "$X264_ARCHIVE" ] || [ -L "$X264_ARCHIVE" ]; then
    fail "Missing regular x264 source archive: $X264_ARCHIVE"
fi
if [ ! -f "$X264_PATCH_FILE" ] || [ -L "$X264_PATCH_FILE" ]; then
    fail "Missing regular x264 source patch: $X264_PATCH_FILE"
fi
if [ ! -f "$X264_SMOKE_FILE" ] || [ -L "$X264_SMOKE_FILE" ]; then
    fail "Missing regular x264 encode smoke: $X264_SMOKE_FILE"
fi
if [ ! -f "$FFMPEG_WRAPPER_SMOKE_FILE" ] || [ -L "$FFMPEG_WRAPPER_SMOKE_FILE" ]; then
    fail "Missing regular FFmpeg wrapper smoke fixture: $FFMPEG_WRAPPER_SMOKE_FILE"
fi

if [ ! -f "$PATCH_FILE" ]; then
    echo "Missing FFmpeg source patch: $PATCH_FILE" >&2
    exit 1
fi

EXPECTED_SHA256=$(awk -v archive="$ARCHIVE_NAME" '$2 == archive { print $1 }' "$CHECKSUMS")
if [ -z "$EXPECTED_SHA256" ]; then
    echo "No pinned checksum for $ARCHIVE_NAME" >&2
    exit 1
fi

ACTUAL_SHA256=$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "FFmpeg source checksum mismatch" >&2
    echo "Expected: $EXPECTED_SHA256" >&2
    echo "Actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

EXPECTED_X264_SHA256=$(awk -v archive="sources/$X264_ARCHIVE_NAME" '$2 == archive { print $1 }' "$X264_CHECKSUMS")
if [ -z "$EXPECTED_X264_SHA256" ]; then
    fail "No pinned checksum for $X264_ARCHIVE_NAME"
fi
ACTUAL_X264_SHA256=$(shasum -a 256 "$X264_ARCHIVE" | awk '{ print $1 }')
if [ "$ACTUAL_X264_SHA256" != "$EXPECTED_X264_SHA256" ]; then
    fail "x264 source checksum mismatch"
fi

EXPECTED_X264_PATCH_SHA256=$(awk -v patch="patches/$X264_PATCH_NAME" '$2 == patch { print $1 }' "$X264_CHECKSUMS")
if [ -z "$EXPECTED_X264_PATCH_SHA256" ]; then
    fail "No pinned checksum for $X264_PATCH_NAME"
fi
ACTUAL_X264_PATCH_SHA256=$(shasum -a 256 "$X264_PATCH_FILE" | awk '{ print $1 }')
if [ "$ACTUAL_X264_PATCH_SHA256" != "$EXPECTED_X264_PATCH_SHA256" ]; then
    fail "x264 source patch checksum mismatch"
fi

EXPECTED_X264_SMOKE_SHA256=$(awk -v smoke="$X264_SMOKE_NAME" '$2 == smoke { print $1 }' "$X264_CHECKSUMS")
if [ -z "$EXPECTED_X264_SMOKE_SHA256" ]; then
    fail "No pinned checksum for $X264_SMOKE_NAME"
fi
ACTUAL_X264_SMOKE_SHA256=$(shasum -a 256 "$X264_SMOKE_FILE" | awk '{ print $1 }')
if [ "$ACTUAL_X264_SMOKE_SHA256" != "$EXPECTED_X264_SMOKE_SHA256" ]; then
    fail "x264 encode smoke checksum mismatch"
fi

EXPECTED_FFMPEG_WRAPPER_SMOKE_SHA256=$(
    awk -v fixture="$FFMPEG_WRAPPER_SMOKE_NAME" '$2 == fixture { print $1 }' "$CHECKSUMS"
)
if [ -z "$EXPECTED_FFMPEG_WRAPPER_SMOKE_SHA256" ]; then
    fail "No pinned checksum for $FFMPEG_WRAPPER_SMOKE_NAME"
fi
ACTUAL_FFMPEG_WRAPPER_SMOKE_SHA256=$(
    shasum -a 256 "$FFMPEG_WRAPPER_SMOKE_FILE" | awk '{ print $1 }'
)
if [ "$ACTUAL_FFMPEG_WRAPPER_SMOKE_SHA256" != "$EXPECTED_FFMPEG_WRAPPER_SMOKE_SHA256" ]; then
    fail "FFmpeg wrapper smoke fixture checksum mismatch"
fi

EXPECTED_PATCH_SHA256=$(awk -v patch="$PATCH_NAME" '$2 == patch { print $1 }' "$CHECKSUMS")
if [ -z "$EXPECTED_PATCH_SHA256" ]; then
    echo "No pinned checksum for $PATCH_NAME" >&2
    exit 1
fi

ACTUAL_PATCH_SHA256=$(shasum -a 256 "$PATCH_FILE" | awk '{ print $1 }')
if [ "$ACTUAL_PATCH_SHA256" != "$EXPECTED_PATCH_SHA256" ]; then
    echo "FFmpeg source patch checksum mismatch" >&2
    echo "Expected: $EXPECTED_PATCH_SHA256" >&2
    echo "Actual:   $ACTUAL_PATCH_SHA256" >&2
    exit 1
fi

if [ -L /private/tmp ] || [ ! -d /private/tmp ]; then
    fail "Expected /private/tmp to be a real directory"
fi
if [ "$(CDPATH= cd -- /private/tmp && pwd -P)" != "/private/tmp" ]; then
    fail "Unexpected canonical path for /private/tmp"
fi
if [ "$(stat -f '%u' /private/tmp)" != "0" ]; then
    fail "/private/tmp is not owned by root"
fi
if [ "$(stat -f '%Mp:%Lp' /private/tmp)" != "1:777" ]; then
    fail "/private/tmp does not have the expected 1777 permissions"
fi

if [ -e "$WORK_PARENT" ] || [ -L "$WORK_PARENT" ]; then
    require_owned_directory "$WORK_PARENT" "$WORK_PARENT"
    if [ "$(stat -f '%Lp' "$WORK_PARENT")" != "700" ]; then
        fail "Build parent must have 0700 permissions: $WORK_PARENT"
    fi
else
    mkdir -m 700 "$WORK_PARENT"
    require_owned_directory "$WORK_PARENT" "$WORK_PARENT"
fi

if ! mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
    fail "Another FFmpeg build is running, or a stale lock exists: $LOCK_DIR"
fi
LOCK_HELD=1

EXPECTED_WORK_ROOT="$WORK_PARENT/$VERSION-profile$PROFILE_REVISION"
if [ "$WORK_ROOT" != "$EXPECTED_WORK_ROOT" ]; then
    fail "Refusing unexpected FFmpeg work root: $WORK_ROOT"
fi
if [ -e "$WORK_ROOT" ] || [ -L "$WORK_ROOT" ]; then
    require_owned_directory "$WORK_ROOT" "$EXPECTED_WORK_ROOT"
    if [ "$(stat -f '%d' "$WORK_ROOT")" != "$(stat -f '%d' "$WORK_PARENT")" ]; then
        fail "Refusing to remove a work root on another filesystem: $WORK_ROOT"
    fi
    rm -rf "$WORK_ROOT"
fi

mkdir -m 700 "$WORK_ROOT"
require_owned_directory "$WORK_ROOT" "$EXPECTED_WORK_ROOT"
if [ "$(stat -f '%Lp' "$WORK_ROOT")" != "700" ]; then
    fail "Build root must have 0700 permissions: $WORK_ROOT"
fi

mkdir -p \
    "$SOURCE_DIR" \
    "$X264_SOURCE_DIR" \
    "$STAGED_OUTPUT_DIR" \
    "$STAGED_REPORT_DIR" \
    "$STAGED_CHECKSUM_DIR"
if [ ! -f "$PROFILE_SOURCE" ] || [ -L "$PROFILE_SOURCE" ]; then
    fail "Missing regular FFmpeg profile report: $PROFILE_SOURCE"
fi
if [ "$(shasum -a 256 "$PROFILE_SOURCE" | awk '{ print $1 }')" != "$PROFILE_SHA256" ]; then
    fail "Pinned FFmpeg profile report checksum mismatch: $PROFILE_SOURCE"
fi
cp "$PROFILE_SOURCE" "$STAGED_REPORT_DIR/profile.txt"
cp "$PKG_CONFIG_SOURCE" "$PKG_CONFIG_X264"
chmod 755 "$PKG_CONFIG_X264"

verify_patched_target() {
    SOURCE_ROOT=$1
    TARGET=$2
    EXPECTED=$3
    ACTUAL=$(shasum -a 256 "$SOURCE_ROOT/$TARGET" | awk '{ print $1 }')

    if [ "$ACTUAL" != "$EXPECTED" ]; then
        echo "Patched FFmpeg source checksum mismatch: $TARGET" >&2
        echo "Expected: $EXPECTED" >&2
        echo "Actual:   $ACTUAL" >&2
        exit 1
    fi
}

tar -xf "$ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"
tar -xf "$X264_ARCHIVE" --strip-components=1 -C "$X264_SOURCE_DIR"
/usr/bin/patch -d "$SOURCE_DIR" -p1 --forward --batch < "$PATCH_FILE"
/usr/bin/patch -d "$X264_SOURCE_DIR" -p1 --forward --batch < "$X264_PATCH_FILE"

verify_patched_target "$SOURCE_DIR" "$PATCHED_FILE_TARGET" "$PATCHED_FILE_SHA256"
verify_patched_target "$SOURCE_DIR" "$PATCHED_DOC_TARGET" "$PATCHED_DOC_SHA256"

build_x264_architecture() {
    ARCH=$1
    HOST=$2
    BUILD_DIR="$WORK_ROOT/x264-build-$ARCH"
    PREFIX_DIR="$WORK_ROOT/x264-prefix-$ARCH"
    PREFIX_MAP_FLAGS="-ffile-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT -fdebug-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT -fmacro-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT"
    ASM_OPTION=

    # Xcode does not bundle NASM. Keep Intel builds dependency-free; this only
    # affects encoding speed, not CRF semantics or output compatibility.
    if [ "$ARCH" = "x86_64" ]; then
        ASM_OPTION=--disable-asm
    fi

    mkdir -p "$BUILD_DIR" "$PREFIX_DIR"
    (
        cd "$BUILD_DIR"
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            X264_PINNED_REV="$X264_REVISION_NUMBER" \
            X264_PINNED_COMMIT="$X264_SHORT_REVISION" \
            CC="$CLANG" \
            AS="$CLANG" \
            AR="$AR" \
            RANLIB="$RANLIB" \
            STRIP="$STRIP" \
            "$X264_SOURCE_DIR/configure" \
            --host="$HOST" \
            --sysroot="$SDK_PATH" \
            --prefix="$PREFIX_DIR" \
            --enable-static \
            --enable-pic \
            --disable-cli \
            --disable-opencl \
            --bit-depth=all \
            --chroma-format=all \
            $ASM_OPTION \
            --extra-asflags="--sysroot=$SDK_PATH -arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
            --extra-cflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET $PREFIX_MAP_FLAGS" \
            --extra-ldflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET"
    )

    if ! grep -q "^#define X264_REV $X264_REVISION_NUMBER$" "$BUILD_DIR/x264_config.h" || \
       ! grep -q '^#define X264_REV_DIFF 0$' "$BUILD_DIR/x264_config.h" || \
       ! grep -q "^#define X264_VERSION \" r$X264_REVISION_NUMBER $X264_SHORT_REVISION\"$" "$BUILD_DIR/x264_config.h" || \
       ! grep -q "^#define X264_POINTVER \"0.$X264_BUILD.$X264_REVISION_NUMBER $X264_SHORT_REVISION\"$" "$BUILD_DIR/x264_config.h"; then
        fail "x264 compiled version metadata does not match the pinned source"
    fi
    if ! grep -q '^#define X264_BIT_DEPTH     0$' "$BUILD_DIR/x264_config.h"; then
        fail "x264 must expose the all-bit-depth public configuration for $ARCH"
    fi
    if ! grep -q '^#define X264_CHROMA_FORMAT 0$' "$BUILD_DIR/x264_config.h"; then
        fail "x264 must expose the all-chroma public configuration for $ARCH"
    fi
    for BITDEPTH in 8 10; do
        if ! grep -q "^#define HAVE_BITDEPTH$BITDEPTH 1$" "$BUILD_DIR/config.h"; then
            fail "x264 bit-depth implementation is missing for $ARCH: $BITDEPTH"
        fi
    done
    if grep -q '^#define CHROMA_FORMAT ' "$BUILD_DIR/config.h"; then
        fail "x264 chroma support was unexpectedly restricted for $ARCH"
    fi

    make -C "$BUILD_DIR" -j "$JOBS" install-lib-static
    cp "$BUILD_DIR/config.mak" "$STAGED_REPORT_DIR/x264-configure-$ARCH.mak"
    cp "$BUILD_DIR/x264_config.h" "$STAGED_REPORT_DIR/x264-config-$ARCH.h"
    cp "$BUILD_DIR/config.h" "$STAGED_REPORT_DIR/x264-build-config-$ARCH.h"
    cp "$BUILD_DIR/x264.pc" "$STAGED_REPORT_DIR/x264-$ARCH.pc"

    X264_STATIC_LIBRARY_COUNT=$(
        find "$PREFIX_DIR/lib" -type f -name 'libx264*.a' -print |
            wc -l |
            tr -d ' '
    )
    if [ "$X264_STATIC_LIBRARY_COUNT" != "1" ]; then
        fail "Expected exactly one x264 static library for $ARCH"
    fi
    if ! lipo "$PREFIX_DIR/lib/libx264.a" -verify_arch "$ARCH"; then
        fail "x264 archive has the wrong architecture: $ARCH"
    fi
    if ! "$NM" -gU "$PREFIX_DIR/lib/libx264.a" | \
        grep -q "_x264_encoder_open_$X264_BUILD"; then
        fail "x264 ABI symbol is missing for $ARCH"
    fi
    if ! "$NM" -gU "$PREFIX_DIR/lib/libx264.a" | \
        grep -q '_x264_encoder_encode'; then
        fail "x264 encoder symbol is missing for $ARCH"
    fi
    for BITDEPTH in 8 10; do
        for SYMBOL in encoder_open encoder_encode; do
            if ! "$NM" -gU "$PREFIX_DIR/lib/libx264.a" | \
                grep -q "_x264_${BITDEPTH}_${SYMBOL}"; then
                fail "x264 $BITDEPTH-bit $SYMBOL symbol is missing for $ARCH"
            fi
        done
    done

    X264_SMOKE_BINARY="$BUILD_DIR/x264-encode-smoke"
    "$CLANG" \
        --sysroot="$SDK_PATH" \
        -arch "$ARCH" \
        -mmacosx-version-min="$DEPLOYMENT_TARGET" \
        -std=c11 \
        -Wall \
        -Wextra \
        -Werror \
        -I"$PREFIX_DIR/include" \
        "$X264_SMOKE_FILE" \
        "$PREFIX_DIR/lib/libx264.a" \
        -lpthread \
        -lm \
        -o "$X264_SMOKE_BINARY"
    if ! lipo "$X264_SMOKE_BINARY" -verify_arch "$ARCH"; then
        fail "x264 encode smoke has the wrong architecture: $ARCH"
    fi
    arch "-$ARCH" "$X264_SMOKE_BINARY" \
        > "$STAGED_REPORT_DIR/x264-encode-smoke-$ARCH.txt"

    DEPLOYMENT_OBJECT="$BUILD_DIR/common/osdep.o"
    if [ "$ARCH" = "arm64" ]; then
        DEPLOYMENT_OBJECT="$BUILD_DIR/common/aarch64/bitstream-a-8.o"
    fi
    OBJECT_MINIMUM=$(
        "$VTOOL" -show-build "$DEPLOYMENT_OBJECT" |
            awk '$1 == "minos" { print $2 }'
    )
    if [ "$OBJECT_MINIMUM" != "$DEPLOYMENT_TARGET" ]; then
        fail "x264 object has unexpected minimum macOS version: $OBJECT_MINIMUM"
    fi
}

build_architecture() {
    ARCH=$1
    FFMPEG_ARCH=$2
    BUILD_DIR="$WORK_ROOT/build-$ARCH"
    PREFIX_DIR="$VIRTUAL_PREFIX_ROOT/$ARCH"
    PREFIX_MAP_FLAGS="-ffile-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT -fdebug-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT -fmacro-prefix-map=$WORK_ROOT=$MAPPED_BUILD_ROOT"

    mkdir -p "$BUILD_DIR"

    if [ -e "$BUILD_DIR/src" ] && [ ! -L "$BUILD_DIR/src" ]; then
        echo "Unexpected non-symlink source entry: $BUILD_DIR/src" >&2
        exit 1
    fi
    if [ ! -L "$BUILD_DIR/src" ]; then
        ln -s ../source "$BUILD_DIR/src"
    fi

    (
        cd "$BUILD_DIR"
        MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
            X264_PREFIX="$WORK_ROOT/x264-prefix-$ARCH" \
            ./src/configure \
            --prefix="$PREFIX_DIR" \
            --target-os=darwin \
            --extra-version="$LIBX264_PROFILE_IDENTIFIER" \
            --arch="$FFMPEG_ARCH" \
            --cpu=generic \
            --enable-cross-compile \
            --sysroot="$SDK_PATH" \
            --cc="$CLANG" \
            --ar="$AR" \
            --ranlib="$RANLIB" \
            --strip="$STRIP" \
            --pkg-config="$PKG_CONFIG_X264" \
            --pkg-config-flags=--static \
            --extra-cflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET $PREFIX_MAP_FLAGS" \
            --extra-ldflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
            --disable-autodetect \
            --disable-everything \
            --disable-network \
            --disable-avdevice \
            --disable-ffplay \
            --disable-doc \
            --disable-debug \
            --disable-shared \
            --enable-static \
            --disable-x86asm \
            --disable-iconv \
            --disable-audiotoolbox \
            --enable-ffmpeg \
            --enable-ffprobe \
            --enable-protocol=fd \
            --enable-protocol=file \
            --enable-protocol=pipe \
            --enable-demuxer=mov \
            --enable-muxer=mp4 \
            --enable-decoder=h264 \
            --enable-decoder=hevc \
            --enable-decoder=aac \
            --enable-parser=h264 \
            --enable-parser=hevc \
            --enable-parser=aac \
            --enable-gpl \
            --enable-libx264 \
            --enable-encoder=libx264 \
            --enable-encoder=aac \
            --enable-filter=scale \
            --enable-filter=aresample \
            --fatal-warnings
    )

    make -C "$BUILD_DIR" -j "$JOBS" ffmpeg ffprobe

    for TOOL in ffmpeg ffprobe; do
        TOOL_MINIMUM=$(
            "$VTOOL" -show-build "$BUILD_DIR/$TOOL" |
                awk '$1 == "minos" { print $2 }'
        )
        if [ "$TOOL_MINIMUM" != "$DEPLOYMENT_TARGET" ]; then
            fail "$TOOL has unexpected minimum macOS version: $TOOL_MINIMUM"
        fi
    done

    cp "$BUILD_DIR/ffbuild/config.mak" "$STAGED_REPORT_DIR/configure-$ARCH.mak"
}

smoke_ffmpeg_wrapper_architecture() {
    ARCH=$1
    BUILD_DIR="$WORK_ROOT/build-$ARCH"
    SMOKE_OUTPUT_DIR="$WORK_ROOT/ffmpeg-wrapper-smoke-$ARCH"
    SMOKE_REPORT="$STAGED_REPORT_DIR/ffmpeg-wrapper-encode-smoke-$ARCH.txt"

    mkdir -p "$SMOKE_OUTPUT_DIR"
    {
        printf 'fixture=%s\n' "$FFMPEG_WRAPPER_SMOKE_NAME"
        printf 'fixture_sha256=%s\n' "$ACTUAL_FFMPEG_WRAPPER_SMOKE_SHA256"
    } > "$SMOKE_REPORT"

    for PIXEL_FORMAT in \
        yuv420p \
        yuv420p10le \
        yuv422p10le \
        yuv444p10le; do
        SMOKE_OUTPUT="$SMOKE_OUTPUT_DIR/$PIXEL_FORMAT.mp4"
        arch "-$ARCH" "$BUILD_DIR/ffmpeg" \
            -hide_banner \
            -loglevel error \
            -nostdin \
            -i "$FFMPEG_WRAPPER_SMOKE_FILE" \
            -map 0:v:0 \
            -an \
            -frames:v 2 \
            -vf scale=64:64:flags=bilinear \
            -c:v libx264 \
            -preset medium \
            -crf 22 \
            -pix_fmt "$PIXEL_FORMAT" \
            -movflags +faststart \
            -y \
            "$SMOKE_OUTPUT"

        if [ ! -s "$SMOKE_OUTPUT" ]; then
            fail "FFmpeg wrapper smoke produced no output for $ARCH/$PIXEL_FORMAT"
        fi

        ACTUAL_CODEC=$(
            arch "-$ARCH" "$BUILD_DIR/ffprobe" \
                -v error \
                -select_streams v:0 \
                -show_entries stream=codec_name \
                -of default=noprint_wrappers=1:nokey=1 \
                "$SMOKE_OUTPUT"
        )
        ACTUAL_PIXEL_FORMAT=$(
            arch "-$ARCH" "$BUILD_DIR/ffprobe" \
                -v error \
                -select_streams v:0 \
                -show_entries stream=pix_fmt \
                -of default=noprint_wrappers=1:nokey=1 \
                "$SMOKE_OUTPUT"
        )
        if [ "$ACTUAL_CODEC" != h264 ]; then
            fail "FFmpeg wrapper smoke produced unexpected codec for $ARCH/$PIXEL_FORMAT: $ACTUAL_CODEC"
        fi
        if [ "$ACTUAL_PIXEL_FORMAT" != "$PIXEL_FORMAT" ]; then
            fail "FFmpeg wrapper smoke produced unexpected pixel format for $ARCH/$PIXEL_FORMAT: $ACTUAL_PIXEL_FORMAT"
        fi

        printf 'pixel_format=%s codec_name=h264 output_pixel_format=%s output_nonempty=yes\n' \
            "$PIXEL_FORMAT" \
            "$ACTUAL_PIXEL_FORMAT" \
            >> "$SMOKE_REPORT"
    done

    printf '%s\n' 'status=passed' >> "$SMOKE_REPORT"
    rm -rf "$SMOKE_OUTPUT_DIR"
}

build_x264_architecture arm64 aarch64-apple-darwin
build_x264_architecture x86_64 x86_64-apple-darwin
if ! cmp -s \
    "$STAGED_REPORT_DIR/x264-encode-smoke-arm64.txt" \
    "$STAGED_REPORT_DIR/x264-encode-smoke-x86_64.txt"; then
    fail "x264 encode smoke matrix differs between architecture slices"
fi
{
    printf 'x264 commit: %s\n' "$X264_REVISION"
    printf 'x264 core ABI: %s\n' "$X264_BUILD"
    printf 'x264 compiled version: 0.%s.%s %s\n' \
        "$X264_BUILD" "$X264_REVISION_NUMBER" "$X264_SHORT_REVISION"
} > "$STAGED_REPORT_DIR/x264-version.txt"
build_architecture arm64 aarch64
build_architecture x86_64 x86_64
smoke_ffmpeg_wrapper_architecture arm64
smoke_ffmpeg_wrapper_architecture x86_64
if ! cmp -s \
    "$STAGED_REPORT_DIR/ffmpeg-wrapper-encode-smoke-arm64.txt" \
    "$STAGED_REPORT_DIR/ffmpeg-wrapper-encode-smoke-x86_64.txt"; then
    fail "FFmpeg wrapper encode smoke semantics differ between architecture slices"
fi
{
    printf 'profile_identifier=%s\n' "$LIBX264_PROFILE_IDENTIFIER"
    printf 'binary_version_marker=%s\n' "$LIBX264_PROFILE_IDENTIFIER"
    printf '%s\n' 'bit_depths=8,10'
    printf '%s\n' 'chroma_formats=420,422,444'
    printf '%s\n' 'pixel_formats=yuv420p,yuv420p10le,yuv422p10le,yuv444p10le'
    printf '%s\n' 'x264_api_smoke_matrix=arm64:8x400,8x420,8x422,8x444,10x400,10x420,10x422,10x444;x86_64:8x400,8x420,8x422,8x444,10x400,10x420,10x422,10x444'
    printf '%s\n' 'ffmpeg_wrapper_smoke_matrix=arm64:yuv420p,yuv420p10le,yuv422p10le,yuv444p10le;x86_64:yuv420p,yuv420p10le,yuv422p10le,yuv444p10le'
    printf 'ffmpeg_wrapper_smoke_fixture=%s\n' "$FFMPEG_WRAPPER_SMOKE_NAME"
    printf 'ffmpeg_wrapper_smoke_fixture_sha256=%s\n' "$ACTUAL_FFMPEG_WRAPPER_SMOKE_SHA256"
    printf '%s\n' 'smoke_status=passed'
} > "$STAGED_REPORT_DIR/libx264-profile.txt"

for CAPABILITY in encoders decoders muxers demuxers protocols filters; do
    arch -arm64 "$WORK_ROOT/build-arm64/ffmpeg" \
        -hide_banner "-$CAPABILITY" > "$STAGED_REPORT_DIR/$CAPABILITY-arm64.txt"
    arch -x86_64 "$WORK_ROOT/build-x86_64/ffmpeg" \
        -hide_banner "-$CAPABILITY" > "$STAGED_REPORT_DIR/$CAPABILITY-x86_64.txt"

    if ! cmp -s \
        "$STAGED_REPORT_DIR/$CAPABILITY-arm64.txt" \
        "$STAGED_REPORT_DIR/$CAPABILITY-x86_64.txt"; then
        echo "FFmpeg capability mismatch between slices: $CAPABILITY" >&2
        exit 1
    fi
done

lipo -create \
    "$WORK_ROOT/build-arm64/ffmpeg" \
    "$WORK_ROOT/build-x86_64/ffmpeg" \
    -output "$STAGED_OUTPUT_DIR/ffmpeg"
lipo -create \
    "$WORK_ROOT/build-arm64/ffprobe" \
    "$WORK_ROOT/build-x86_64/ffprobe" \
    -output "$STAGED_OUTPUT_DIR/ffprobe"

chmod 755 "$STAGED_OUTPUT_DIR/ffmpeg" "$STAGED_OUTPUT_DIR/ffprobe"

"$STAGED_OUTPUT_DIR/ffmpeg" -version > "$STAGED_REPORT_DIR/ffmpeg-version.txt"
"$STAGED_OUTPUT_DIR/ffprobe" -version > "$STAGED_REPORT_DIR/ffprobe-version.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -buildconf > "$STAGED_REPORT_DIR/ffmpeg-buildconf.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -encoders > "$STAGED_REPORT_DIR/encoders.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -decoders > "$STAGED_REPORT_DIR/decoders.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -muxers > "$STAGED_REPORT_DIR/muxers.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -demuxers > "$STAGED_REPORT_DIR/demuxers.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -protocols > "$STAGED_REPORT_DIR/protocols.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -filters > "$STAGED_REPORT_DIR/filters.txt"
"$STAGED_OUTPUT_DIR/ffmpeg" -hide_banner -h encoder=libx264 \
    > "$STAGED_REPORT_DIR/libx264-encoder.txt" 2>&1
"$STAGED_OUTPUT_DIR/ffmpeg" -L > "$STAGED_REPORT_DIR/runtime-license.txt"
"$STAGED_OUTPUT_DIR/ffprobe" -L > "$STAGED_REPORT_DIR/runtime-license-ffprobe.txt"

if ! grep -F \
    "ffmpeg version $VERSION-$LIBX264_PROFILE_IDENTIFIER " \
    "$STAGED_REPORT_DIR/ffmpeg-version.txt" >/dev/null; then
    fail "FFmpeg runtime version does not contain the required profile identifier"
fi
if ! grep -F \
    "ffprobe version $VERSION-$LIBX264_PROFILE_IDENTIFIER " \
    "$STAGED_REPORT_DIR/ffprobe-version.txt" >/dev/null; then
    fail "FFprobe runtime version does not contain the required profile identifier"
fi
if ! grep -F \
    -- "--extra-version=$LIBX264_PROFILE_IDENTIFIER" \
    "$STAGED_REPORT_DIR/ffmpeg-buildconf.txt" >/dev/null; then
    fail "FFmpeg build configuration does not contain the required profile identifier"
fi

LIPO_REPORT_RAW="$WORK_ROOT/lipo.txt"
(
    cd "$STAGE_ROOT"
    file Vendor/FFmpeg/bin/ffmpeg Vendor/FFmpeg/bin/ffprobe \
        > "$STAGED_REPORT_DIR/file.txt"
    lipo -info Vendor/FFmpeg/bin/ffmpeg > "$LIPO_REPORT_RAW"
    lipo -info Vendor/FFmpeg/bin/ffprobe >> "$LIPO_REPORT_RAW"
    otool -L Vendor/FFmpeg/bin/ffmpeg > "$STAGED_REPORT_DIR/otool.txt"
    otool -L Vendor/FFmpeg/bin/ffprobe >> "$STAGED_REPORT_DIR/otool.txt"
)
sed 's/[[:space:]]*$//' "$LIPO_REPORT_RAW" > "$STAGED_REPORT_DIR/lipo.txt"
xcodebuild -version > "$STAGED_REPORT_DIR/toolchain.txt"
xcrun --sdk macosx --show-sdk-version >> "$STAGED_REPORT_DIR/toolchain.txt"
printf '%s\n' "$SDK_PATH" >> "$STAGED_REPORT_DIR/toolchain.txt"

if ! lipo "$STAGED_OUTPUT_DIR/ffmpeg" -verify_arch arm64 x86_64; then
    fail "FFmpeg output is not Universal 2"
fi
if ! lipo "$STAGED_OUTPUT_DIR/ffprobe" -verify_arch arm64 x86_64; then
    fail "FFprobe output is not Universal 2"
fi
if ! grep -q ' libx264 ' "$STAGED_REPORT_DIR/encoders.txt"; then
    echo "Required libx264 encoder is missing" >&2
    exit 1
fi
for PIXEL_FORMAT in \
    yuv420p \
    yuv420p10le \
    yuv422p10le \
    yuv444p10le; do
    if ! awk -v pixel_format="$PIXEL_FORMAT" '
        /^    Supported pixel formats:/ {
            for (field = 4; field <= NF; field++)
                if ($field == pixel_format)
                    found = 1
        }
        END { exit !found }
    ' "$STAGED_REPORT_DIR/libx264-encoder.txt"; then
        fail "Required libx264 pixel format is missing: $PIXEL_FORMAT"
    fi
done
if grep -q 'hevc_videotoolbox' "$STAGED_REPORT_DIR/encoders.txt"; then
    fail "Unused hevc_videotoolbox encoder is present"
fi
if ! grep -q ' aac ' "$STAGED_REPORT_DIR/encoders.txt"; then
    echo "Required native AAC encoder is missing" >&2
    exit 1
fi
for REQUIRED_DECODER in h264 hevc aac; do
    if ! awk -v decoder="$REQUIRED_DECODER" '
        $2 == decoder { found = 1 }
        END { exit !found }
    ' "$STAGED_REPORT_DIR/decoders.txt"; then
        fail "Required native decoder is missing: $REQUIRED_DECODER"
    fi
done
if ! grep -q -- '--enable-gpl' "$STAGED_REPORT_DIR/ffmpeg-buildconf.txt" || \
   ! grep -q -- '--enable-libx264' "$STAGED_REPORT_DIR/ffmpeg-buildconf.txt"; then
    fail "Required GPL/libx264 FFmpeg configuration is missing"
fi
if grep -Eq 'enable-(version3|nonfree|libx265)' "$STAGED_REPORT_DIR/ffmpeg-buildconf.txt"; then
    echo "Forbidden FFmpeg licensing option detected" >&2
    exit 1
fi
for CONFIG_REPORT in \
    "$STAGED_REPORT_DIR/configure-arm64.mak" \
    "$STAGED_REPORT_DIR/configure-x86_64.mak"; do
    if ! grep -q '^CONFIG_GPL=yes$' "$CONFIG_REPORT"; then
        fail "FFmpeg GPL mode is missing from $CONFIG_REPORT"
    fi
    if ! grep -q '^CONFIG_LIBX264=yes$' "$CONFIG_REPORT"; then
        fail "Static libx264 support is missing from $CONFIG_REPORT"
    fi
    if ! grep -q '^!CONFIG_HEVC_VIDEOTOOLBOX_ENCODER=yes$' "$CONFIG_REPORT"; then
        fail "Unused HEVC VideoToolbox encoder is not fail-closed in $CONFIG_REPORT"
    fi
    for DISABLED_LICENSE_MODE in VERSION3 NONFREE; do
        if ! grep -q "^!CONFIG_$DISABLED_LICENSE_MODE=yes$" "$CONFIG_REPORT"; then
            fail "FFmpeg license mode is not fail-closed in $CONFIG_REPORT: $DISABLED_LICENSE_MODE"
        fi
    done
    for REQUIRED_COMPONENT in \
        H264_DECODER \
        HEVC_DECODER \
        AAC_DECODER \
        H264_PARSER \
        HEVC_PARSER \
        AAC_PARSER \
        LIBX264_ENCODER \
        AAC_ENCODER; do
        if ! grep -q "^CONFIG_$REQUIRED_COMPONENT=yes$" "$CONFIG_REPORT"; then
            fail "Required FFmpeg component is missing from $CONFIG_REPORT: $REQUIRED_COMPONENT"
        fi
    done
done
for LICENSE_REPORT in \
    "$STAGED_REPORT_DIR/runtime-license.txt" \
    "$STAGED_REPORT_DIR/runtime-license-ffprobe.txt"; do
    if ! grep -q 'GNU General Public License' "$LICENSE_REPORT"; then
        fail "FFmpeg runtime does not report the required GPL license: $LICENSE_REPORT"
    fi
done
if grep -Eq '/(opt/homebrew|usr/local|opt/local)/' "$STAGED_REPORT_DIR/otool.txt"; then
    echo "Unexpected package-manager linkage detected" >&2
    exit 1
fi
if ! awk '
    /^\t/ && $1 !~ /^\/(System\/Library|usr\/lib)\// { unexpected = 1 }
    END { exit unexpected }
' "$STAGED_REPORT_DIR/otool.txt"; then
    fail "Unexpected non-system linkage detected"
fi

codesign --force \
    --sign - \
    --identifier com.example.Resizer.ffmpeg \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$STAGED_OUTPUT_DIR/ffmpeg"
codesign --force \
    --sign - \
    --identifier com.example.Resizer.ffprobe \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$STAGED_OUTPUT_DIR/ffprobe"

codesign --verify --strict --verbose=2 "$STAGED_OUTPUT_DIR/ffmpeg"
codesign --verify --strict --verbose=2 "$STAGED_OUTPUT_DIR/ffprobe"

CODESIGN_FFMPEG_RAW="$WORK_ROOT/codesign-ffmpeg.txt"
CODESIGN_FFPROBE_RAW="$WORK_ROOT/codesign-ffprobe.txt"
codesign -dvvv --entitlements :- "$STAGED_OUTPUT_DIR/ffmpeg" \
    > "$CODESIGN_FFMPEG_RAW" 2>&1
codesign -dvvv --entitlements :- "$STAGED_OUTPUT_DIR/ffprobe" \
    > "$CODESIGN_FFPROBE_RAW" 2>&1
sed "s|$STAGE_ROOT|<REPOSITORY_ROOT>|g" \
    "$CODESIGN_FFMPEG_RAW" > "$STAGED_REPORT_DIR/codesign-ffmpeg.txt"
sed "s|$STAGE_ROOT|<REPOSITORY_ROOT>|g" \
    "$CODESIGN_FFPROBE_RAW" > "$STAGED_REPORT_DIR/codesign-ffprobe.txt"

if ! grep -q '^Identifier=com.example.Resizer.ffmpeg$' "$STAGED_REPORT_DIR/codesign-ffmpeg.txt"; then
    fail "Unexpected FFmpeg code-signing identifier"
fi
if ! grep -q '^Identifier=com.example.Resizer.ffprobe$' "$STAGED_REPORT_DIR/codesign-ffprobe.txt"; then
    fail "Unexpected FFprobe code-signing identifier"
fi
for CODESIGN_REPORT in \
    "$STAGED_REPORT_DIR/codesign-ffmpeg.txt" \
    "$STAGED_REPORT_DIR/codesign-ffprobe.txt"; do
    if ! grep -q '<key>com.apple.security.app-sandbox</key><true/>' "$CODESIGN_REPORT"; then
        fail "Sandbox entitlement missing from $CODESIGN_REPORT"
    fi
    if ! grep -q '<key>com.apple.security.inherit</key><true/>' "$CODESIGN_REPORT"; then
        fail "Sandbox inheritance entitlement missing from $CODESIGN_REPORT"
    fi
done

for TOOL in "$STAGED_OUTPUT_DIR/ffmpeg" "$STAGED_OUTPUT_DIR/ffprobe"; do
    if strings "$TOOL" | grep -Eq '/Users/[^/]+/'; then
        echo "User-specific absolute path embedded in $TOOL" >&2
        exit 1
    fi
    if strings "$TOOL" | grep -F "$ROOT_DIR" >/dev/null; then
        echo "Repository path embedded in $TOOL" >&2
        exit 1
    fi
done

if grep -R -F "$ROOT_DIR" "$STAGED_REPORT_DIR" >/dev/null; then
    echo "Repository path leaked into FFmpeg build reports" >&2
    exit 1
fi
if grep -R -E '/Users/[^/]+/' "$STAGED_REPORT_DIR" >/dev/null; then
    fail "User-specific path leaked into FFmpeg build reports"
fi

chmod 755 "$STAGED_OUTPUT_DIR" "$STAGED_REPORT_DIR"
chmod 644 "$STAGED_REPORT_DIR"/*

(
    cd "$STAGE_ROOT"
    shasum -a 256 \
        Vendor/FFmpeg/bin/ffmpeg \
        Vendor/FFmpeg/bin/ffprobe \
        Vendor/FFmpeg/build-config/* \
        > "$STAGED_BUILD_CHECKSUMS"
    shasum -a 256 -c "$STAGED_BUILD_CHECKSUMS"
)
chmod 644 "$STAGED_BUILD_CHECKSUMS"

# Revalidate every publication destination after all staged checks. Nothing in
# bin/, build-config/, or BUILD_SHA256SUMS is changed before this point.
require_owned_directory "$VENDOR_DIR" "$VENDOR_DIR"
require_owned_directory "$OUTPUT_DIR" "$OUTPUT_DIR"
require_owned_directory "$REPORT_DIR" "$REPORT_DIR"
require_owned_directory "$CHECKSUM_DIR" "$CHECKSUM_DIR"
if [ ! -f "$BUILD_CHECKSUMS" ] || [ -L "$BUILD_CHECKSUMS" ]; then
    fail "Expected a regular build checksum manifest: $BUILD_CHECKSUMS"
fi
for RESERVED_PATH in \
    "$PUBLISH_ROOT" \
    "$OLD_OUTPUT_DIR" \
    "$OLD_REPORT_DIR" \
    "$OLD_BUILD_CHECKSUMS"; do
    if [ -e "$RESERVED_PATH" ] || [ -L "$RESERVED_PATH" ]; then
        fail "Refusing to reuse FFmpeg publication path: $RESERVED_PATH"
    fi
done

mkdir -m 700 "$PUBLISH_ROOT"
PUBLISH_ROOT_CREATED=1
mkdir -p "$PUBLISH_ROOT/root"
cp -Rp "$STAGE_ROOT/Vendor" "$PUBLISH_ROOT/root/Vendor"

if [ "$(stat -f '%Lp' "$PUBLISH_ROOT/root/Vendor/FFmpeg/bin")" != "755" ] || \
   [ "$(stat -f '%Lp' "$PUBLISH_ROOT/root/Vendor/FFmpeg/build-config")" != "755" ]; then
    fail "Published FFmpeg directories do not preserve the required 0755 mode"
fi
for PUBLISHED_TOOL in \
    "$PUBLISH_ROOT/root/Vendor/FFmpeg/bin/ffmpeg" \
    "$PUBLISH_ROOT/root/Vendor/FFmpeg/bin/ffprobe"; do
    if [ "$(stat -f '%Lp' "$PUBLISHED_TOOL")" != "755" ]; then
        fail "Published FFmpeg tool does not preserve the required 0755 mode: $PUBLISHED_TOOL"
    fi
done
for PUBLISHED_REPORT in "$PUBLISH_ROOT/root/Vendor/FFmpeg/build-config"/*; do
    if [ "$(stat -f '%Lp' "$PUBLISHED_REPORT")" != "644" ]; then
        fail "Published FFmpeg report does not preserve the required 0644 mode: $PUBLISHED_REPORT"
    fi
done
if [ "$(stat -f '%Lp' "$PUBLISH_ROOT/root/Vendor/FFmpeg/checksums/BUILD_SHA256SUMS")" != "644" ]; then
    fail "Published FFmpeg checksum manifest does not preserve the required 0644 mode"
fi
(
    cd "$PUBLISH_ROOT/root"
    shasum -a 256 -c Vendor/FFmpeg/checksums/BUILD_SHA256SUMS
)

# Keep the previous set available until all three replacements have landed so
# ordinary failures and termination signals can restore a coherent set.
PUBLISH_ACTIVE=1
mv "$OUTPUT_DIR" "$OLD_OUTPUT_DIR"
mv "$PUBLISH_ROOT/root/Vendor/FFmpeg/bin" "$OUTPUT_DIR"
mv "$REPORT_DIR" "$OLD_REPORT_DIR"
mv "$PUBLISH_ROOT/root/Vendor/FFmpeg/build-config" "$REPORT_DIR"
mv "$BUILD_CHECKSUMS" "$OLD_BUILD_CHECKSUMS"
mv "$PUBLISH_ROOT/root/Vendor/FFmpeg/checksums/BUILD_SHA256SUMS" "$BUILD_CHECKSUMS"
PUBLISH_ACTIVE=0

rm -rf "$OLD_OUTPUT_DIR" "$OLD_REPORT_DIR"
rm -f "$OLD_BUILD_CHECKSUMS"

echo "Built Universal 2 FFmpeg $VERSION in $OUTPUT_DIR"
