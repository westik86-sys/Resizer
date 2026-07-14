#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

VERSION=8.1.2
PROFILE_REVISION=3
DEPLOYMENT_TARGET=14.0
ARCHIVE_NAME="ffmpeg-$VERSION.tar.xz"
ARCHIVE="$ROOT_DIR/Vendor/FFmpeg/sources/$ARCHIVE_NAME"
PATCH_NAME="0001-avformat-fd-accept-descriptor-in-url.patch"
PATCH_FILE="$ROOT_DIR/Vendor/FFmpeg/patches/$PATCH_NAME"
PATCHED_FILE_TARGET="libavformat/file.c"
PATCHED_FILE_SHA256=f003462660d1d624ff16dfb36d20821defcc75dbe6d80bd9fd10886763bc9289
PATCHED_DOC_TARGET="doc/protocols.texi"
PATCHED_DOC_SHA256=ee61a56dd221eb48489e9954dbe3954e4ebe990f5db65432769d9beb077f45d0
CHECKSUMS="$ROOT_DIR/Vendor/FFmpeg/checksums/SHA256SUMS"
WORK_ROOT="${FFMPEG_BUILD_ROOT:-$ROOT_DIR/.build/ffmpeg/$VERSION-profile$PROFILE_REVISION}"
SOURCE_DIR="$WORK_ROOT/source"
OUTPUT_DIR="$ROOT_DIR/Vendor/FFmpeg/bin"
REPORT_DIR="$ROOT_DIR/Vendor/FFmpeg/build-config"
ENTITLEMENTS="$ROOT_DIR/Configuration/FFmpegHelper.entitlements"
PKG_CONFIG_DISABLED="$SCRIPT_DIR/support/pkg-config-disabled"

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
CLANG=$(xcrun --sdk macosx --find clang)
AR=$(xcrun --sdk macosx --find ar)
RANLIB=$(xcrun --sdk macosx --find ranlib)
STRIP=$(xcrun --sdk macosx --find strip)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN)}

if [ ! -f "$ARCHIVE" ]; then
    echo "Missing FFmpeg source archive: $ARCHIVE" >&2
    exit 1
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

mkdir -p "$WORK_ROOT" "$OUTPUT_DIR" "$REPORT_DIR"

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

if [ ! -x "$SOURCE_DIR/configure" ]; then
    STAGING_SOURCE="$WORK_ROOT/source-staging-$$"
    mkdir -p "$STAGING_SOURCE"
    tar -xf "$ARCHIVE" --strip-components=1 -C "$STAGING_SOURCE"
    /usr/bin/patch -d "$STAGING_SOURCE" -p1 --forward --batch < "$PATCH_FILE"

    verify_patched_target "$STAGING_SOURCE" "$PATCHED_FILE_TARGET" "$PATCHED_FILE_SHA256"
    verify_patched_target "$STAGING_SOURCE" "$PATCHED_DOC_TARGET" "$PATCHED_DOC_SHA256"

    mv "$STAGING_SOURCE" "$SOURCE_DIR"
fi

verify_patched_target "$SOURCE_DIR" "$PATCHED_FILE_TARGET" "$PATCHED_FILE_SHA256"
verify_patched_target "$SOURCE_DIR" "$PATCHED_DOC_TARGET" "$PATCHED_DOC_SHA256"

build_architecture() {
    ARCH=$1
    FFMPEG_ARCH=$2
    BUILD_DIR="$WORK_ROOT/build-$ARCH"
    PREFIX_DIR="$WORK_ROOT/install-$ARCH"

    mkdir -p "$BUILD_DIR" "$PREFIX_DIR"

    if [ ! -f "$BUILD_DIR/ffbuild/config.mak" ]; then
        (
            cd "$BUILD_DIR"
            MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
                "$SOURCE_DIR/configure" \
                --prefix="$PREFIX_DIR" \
                --target-os=darwin \
                --arch="$FFMPEG_ARCH" \
                --cpu=generic \
                --enable-cross-compile \
                --sysroot="$SDK_PATH" \
                --cc="$CLANG" \
                --ar="$AR" \
                --ranlib="$RANLIB" \
                --strip="$STRIP" \
                --pkg-config="$PKG_CONFIG_DISABLED" \
                --extra-cflags="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
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
                --enable-videotoolbox \
                --enable-ffmpeg \
                --enable-ffprobe \
                --enable-protocol=fd \
                --enable-protocol=file \
                --enable-protocol=pipe \
                --enable-demuxer=mov \
                --enable-muxer=mp4 \
                --enable-decoder=h264 \
                --enable-decoder=aac \
                --enable-parser=h264 \
                --enable-parser=aac \
                --enable-encoder=h264_videotoolbox \
                --enable-encoder=aac \
                --enable-filter=scale \
                --enable-filter=aresample \
                --fatal-warnings
        )
    fi

    make -C "$BUILD_DIR" -j "$JOBS" ffmpeg ffprobe

    cp "$BUILD_DIR/ffbuild/config.mak" "$REPORT_DIR/configure-$ARCH.mak"
}

build_architecture arm64 aarch64
build_architecture x86_64 x86_64

for CAPABILITY in encoders decoders muxers demuxers protocols filters; do
    arch -arm64 "$WORK_ROOT/build-arm64/ffmpeg" \
        -hide_banner "-$CAPABILITY" > "$REPORT_DIR/$CAPABILITY-arm64.txt"
    arch -x86_64 "$WORK_ROOT/build-x86_64/ffmpeg" \
        -hide_banner "-$CAPABILITY" > "$REPORT_DIR/$CAPABILITY-x86_64.txt"

    if ! cmp -s \
        "$REPORT_DIR/$CAPABILITY-arm64.txt" \
        "$REPORT_DIR/$CAPABILITY-x86_64.txt"; then
        echo "FFmpeg capability mismatch between slices: $CAPABILITY" >&2
        exit 1
    fi
done

lipo -create \
    "$WORK_ROOT/build-arm64/ffmpeg" \
    "$WORK_ROOT/build-x86_64/ffmpeg" \
    -output "$OUTPUT_DIR/ffmpeg"
lipo -create \
    "$WORK_ROOT/build-arm64/ffprobe" \
    "$WORK_ROOT/build-x86_64/ffprobe" \
    -output "$OUTPUT_DIR/ffprobe"

chmod 755 "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"

"$OUTPUT_DIR/ffmpeg" -version > "$REPORT_DIR/ffmpeg-version.txt"
"$OUTPUT_DIR/ffprobe" -version > "$REPORT_DIR/ffprobe-version.txt"
"$OUTPUT_DIR/ffmpeg" -buildconf > "$REPORT_DIR/ffmpeg-buildconf.txt"
"$OUTPUT_DIR/ffmpeg" -encoders > "$REPORT_DIR/encoders.txt"
"$OUTPUT_DIR/ffmpeg" -decoders > "$REPORT_DIR/decoders.txt"
"$OUTPUT_DIR/ffmpeg" -muxers > "$REPORT_DIR/muxers.txt"
"$OUTPUT_DIR/ffmpeg" -demuxers > "$REPORT_DIR/demuxers.txt"
"$OUTPUT_DIR/ffmpeg" -protocols > "$REPORT_DIR/protocols.txt"
"$OUTPUT_DIR/ffmpeg" -filters > "$REPORT_DIR/filters.txt"
"$OUTPUT_DIR/ffmpeg" -L > "$REPORT_DIR/runtime-license.txt"

file "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe" > "$REPORT_DIR/file.txt"
lipo -info "$OUTPUT_DIR/ffmpeg" > "$REPORT_DIR/lipo.txt"
lipo -info "$OUTPUT_DIR/ffprobe" >> "$REPORT_DIR/lipo.txt"
otool -L "$OUTPUT_DIR/ffmpeg" > "$REPORT_DIR/otool.txt"
otool -L "$OUTPUT_DIR/ffprobe" >> "$REPORT_DIR/otool.txt"
xcodebuild -version > "$REPORT_DIR/toolchain.txt"
xcrun --sdk macosx --show-sdk-version >> "$REPORT_DIR/toolchain.txt"
printf '%s\n' "$SDK_PATH" >> "$REPORT_DIR/toolchain.txt"

if ! grep -q 'h264_videotoolbox' "$REPORT_DIR/encoders.txt"; then
    echo "Required h264_videotoolbox encoder is missing" >&2
    exit 1
fi
if ! grep -q ' aac ' "$REPORT_DIR/encoders.txt"; then
    echo "Required native AAC encoder is missing" >&2
    exit 1
fi
if grep -Eq 'enable-(gpl|nonfree|libx264|libx265)' "$REPORT_DIR/ffmpeg-buildconf.txt"; then
    echo "Forbidden FFmpeg licensing option detected" >&2
    exit 1
fi
if grep -Eq '/(opt/homebrew|usr/local|opt/local)/' "$REPORT_DIR/otool.txt"; then
    echo "Unexpected package-manager linkage detected" >&2
    exit 1
fi

codesign --force \
    --sign - \
    --identifier com.example.Resizer.ffmpeg \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$OUTPUT_DIR/ffmpeg"
codesign --force \
    --sign - \
    --identifier com.example.Resizer.ffprobe \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$OUTPUT_DIR/ffprobe"

codesign --verify --strict --verbose=2 "$OUTPUT_DIR/ffmpeg"
codesign --verify --strict --verbose=2 "$OUTPUT_DIR/ffprobe"
codesign -dvvv --entitlements :- "$OUTPUT_DIR/ffmpeg" \
    > "$REPORT_DIR/codesign-ffmpeg.txt" 2>&1
codesign -dvvv --entitlements :- "$OUTPUT_DIR/ffprobe" \
    > "$REPORT_DIR/codesign-ffprobe.txt" 2>&1

echo "Built Universal 2 FFmpeg $VERSION in $OUTPUT_DIR"
