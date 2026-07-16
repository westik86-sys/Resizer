#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=release-common.sh
. "$SCRIPT_DIR/release-common.sh"

release_initialize
release_validate_team_id "${DEVELOPMENT_TEAM:-}"

if [ "$#" -ne 1 ]; then
    release_fail "Usage: NOTARY_PROFILE=<Keychain profile> $0 <Resizer.dmg>"
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    release_fail "NOTARY_PROFILE must name credentials stored by notarytool in Keychain"
fi
case "$NOTARY_PROFILE" in
    *[!A-Za-z0-9._-]*) release_fail "NOTARY_PROFILE contains an unsafe character" ;;
esac

case "$1" in
    /*) DMG_PATH=$1 ;;
    *) DMG_PATH="$RELEASE_ROOT_DIR/$1" ;;
esac
release_require_direct_child_path "$DMG_PATH" "$RESIZER_RELEASE_ROOT"
case "$(basename "$DMG_PATH")" in
    *.dmg) ;;
    *) release_fail "The release artifact must use the .dmg extension" ;;
esac
release_require_regular_file "$DMG_PATH"

for COMMAND in codesign plutil spctl xcrun; do
    release_require_command "$COMMAND"
done
release_require_developer_id_authority "$DMG_PATH"
release_invalidate_checksums

EVIDENCE_DIR="$RESIZER_RELEASE_ROOT/notary"
if [ -L "$EVIDENCE_DIR" ]; then
    release_fail "Refusing symlinked notary evidence directory"
fi
if [ ! -e "$EVIDENCE_DIR" ]; then
    mkdir -m 700 "$EVIDENCE_DIR"
fi
release_require_real_directory "$EVIDENCE_DIR"

ARTIFACT_STEM=$(basename "$DMG_PATH" .dmg)
RESULT_PATH="$EVIDENCE_DIR/$ARTIFACT_STEM.plist"
LOG_PATH="$EVIDENCE_DIR/$ARTIFACT_STEM-log.json"
RESULT_TEMP="$EVIDENCE_DIR/.$ARTIFACT_STEM.$$.plist"
release_require_new_path "$RESULT_PATH"
release_require_new_path "$LOG_PATH"
release_require_new_path "$RESULT_TEMP"

cleanup() {
    STATUS=$?
    trap - 0 1 2 15
    rm -f "$RESULT_TEMP"
    exit "$STATUS"
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

release_note "Submitting DMG to Apple Notary service"
if ! xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --no-progress \
    --output-format plist > "$RESULT_TEMP"; then
    cat "$RESULT_TEMP" >&2
    release_fail "Notary submission command failed"
fi

NOTARY_STATUS=$(plutil -extract status raw "$RESULT_TEMP")
SUBMISSION_ID=$(plutil -extract id raw "$RESULT_TEMP")
mv "$RESULT_TEMP" "$RESULT_PATH"

if [ "$NOTARY_STATUS" != "Accepted" ]; then
    xcrun notarytool log "$SUBMISSION_ID" "$LOG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" || true
    release_fail "Notary service returned $NOTARY_STATUS; inspect $LOG_PATH"
fi

release_note "Stapling and validating the notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess \
    --type open \
    --context context:primary-signature \
    --verbose=2 \
    "$DMG_PATH"

release_note "Notarized DMG: $DMG_PATH"
echo "Submission evidence: $RESULT_PATH"
echo "Run verify-release.sh next; it writes the final post-stapling checksums."
