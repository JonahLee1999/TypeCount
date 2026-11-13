#!/bin/bash
set -euo pipefail
TYPECOUNT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TYPECOUNT_ROOT"

TYPECOUNT_SOURCE="$TYPECOUNT_ROOT/dist/TypeCount.app"
TYPECOUNT_INFO="$TYPECOUNT_SOURCE/Contents/Info.plist"
TYPECOUNT_TOOLS="$TYPECOUNT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
TYPECOUNT_ACCOUNT="com.jonah.TypeCount.sparkle"
TYPECOUNT_REPOSITORY="https://github.com/JonahLee1999/TypeCount"
TYPECOUNT_EXPECTED_FEED="$TYPECOUNT_REPOSITORY/releases/latest/download/appcast.xml"

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

read_info() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$TYPECOUNT_INFO" 2>/dev/null || \
        fail "Missing required Info.plist value: $1. Rebuild the release app first."
}

[ -d "$TYPECOUNT_SOURCE" ] || fail 'Build the release app first: UNIVERSAL=1 ./scripts/build-app.sh'
for TYPECOUNT_TOOL in generate_keys generate_appcast sign_update; do
    [ -x "$TYPECOUNT_TOOLS/$TYPECOUNT_TOOL" ] || fail 'Sparkle release tools are missing. Run swift package resolve first.'
done

codesign --verify --deep --strict "$TYPECOUNT_SOURCE"
lipo "$TYPECOUNT_SOURCE/Contents/MacOS/TypeCount" -verify_arch arm64 x86_64
TYPECOUNT_VERSION="$(read_info CFBundleShortVersionString)"
TYPECOUNT_BUILD="$(read_info CFBundleVersion)"
TYPECOUNT_PUBLIC_KEY="$(read_info SUPublicEDKey)"
TYPECOUNT_FEED="$(read_info SUFeedURL)"
TYPECOUNT_REQUIRE_SIGNED_FEED="$(read_info SURequireSignedFeed)"
TYPECOUNT_VERIFY_BEFORE_EXTRACTION="$(read_info SUVerifyUpdateBeforeExtraction)"
[[ "$TYPECOUNT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected a three-part numeric release version.'
[[ "$TYPECOUNT_BUILD" =~ ^[0-9]+$ ]] || fail 'Expected a numeric CFBundleVersion.'
[ -n "$TYPECOUNT_PUBLIC_KEY" ] || fail 'The app has no embedded Sparkle public key.'
[ "$TYPECOUNT_FEED" = "$TYPECOUNT_EXPECTED_FEED" ] || fail 'The embedded update feed does not match this repository.'
[ "$TYPECOUNT_REQUIRE_SIGNED_FEED" = true ] || fail 'SURequireSignedFeed must be true in the release app.'
[ "$TYPECOUNT_VERIFY_BEFORE_EXTRACTION" = true ] || fail 'SUVerifyUpdateBeforeExtraction must be true in the release app.'

# Lookup-only mode never generates or exports a key. No private key is printed,
# passed on the command line, or written to the staging/output directories.
if ! TYPECOUNT_KEYCHAIN_PUBLIC_KEY="$("$TYPECOUNT_TOOLS/generate_keys" --account "$TYPECOUNT_ACCOUNT" -p)"; then
    printf 'No existing signing key could be read for Keychain account %s.\n' "$TYPECOUNT_ACCOUNT" >&2
    printf 'Restore access to the existing key, or initialize this account once with:\n  %s --account %s\n' \
        "$TYPECOUNT_TOOLS/generate_keys" "$TYPECOUNT_ACCOUNT" >&2
    exit 1
fi
[ "$TYPECOUNT_KEYCHAIN_PUBLIC_KEY" = "$TYPECOUNT_PUBLIC_KEY" ] || \
    fail 'The Keychain signing key does not match SUPublicEDKey embedded in the app. Nothing was signed.'

mkdir -p "$TYPECOUNT_ROOT/.build" "$TYPECOUNT_ROOT/dist/updates"
TYPECOUNT_STAGE="$(mktemp -d "$TYPECOUNT_ROOT/.build/update-stage.XXXXXX")"
trap 'rm -rf "$TYPECOUNT_STAGE"' EXIT
TYPECOUNT_ARCHIVES="$TYPECOUNT_STAGE/archives"
TYPECOUNT_PAYLOAD="$TYPECOUNT_STAGE/payload"
mkdir -p "$TYPECOUNT_ARCHIVES" "$TYPECOUNT_PAYLOAD"
TYPECOUNT_ZIP_NAME="TypeCount-${TYPECOUNT_VERSION}-macOS-universal.zip"
TYPECOUNT_ZIP="$TYPECOUNT_ARCHIVES/$TYPECOUNT_ZIP_NAME"
TYPECOUNT_APPCAST="$TYPECOUNT_ARCHIVES/appcast.xml"
TYPECOUNT_DOWNLOAD_PREFIX="$TYPECOUNT_REPOSITORY/releases/download/v${TYPECOUNT_VERSION}/"

# The archive contains a single app, with its intended installed display name.
# ditto preserves framework symlinks, executable permissions, and resource forks.
ditto "$TYPECOUNT_SOURCE" "$TYPECOUNT_PAYLOAD/字迹.app"
codesign --verify --deep --strict "$TYPECOUNT_PAYLOAD/字迹.app"
ditto -c -k --sequesterRsrc --keepParent "$TYPECOUNT_PAYLOAD/字迹.app" "$TYPECOUNT_ZIP"
if [ -f "$TYPECOUNT_ROOT/Resources/ReleaseNotes.html" ]; then
    cp "$TYPECOUNT_ROOT/Resources/ReleaseNotes.html" "$TYPECOUNT_ARCHIVES/${TYPECOUNT_ZIP_NAME%.zip}.html"
fi

# Scan a fresh directory containing only this release's zip. The embedded
# SURequireSignedFeed flag makes Sparkle 2.10 sign the feed as well as the zip.
"$TYPECOUNT_TOOLS/generate_appcast" \
    --account "$TYPECOUNT_ACCOUNT" \
    --download-url-prefix "$TYPECOUNT_DOWNLOAD_PREFIX" \
    --versions "$TYPECOUNT_BUILD" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --embed-release-notes \
    --link "$TYPECOUNT_REPOSITORY" \
    -o "$TYPECOUNT_APPCAST" \
    "$TYPECOUNT_ARCHIVES"

# Inspect without rewriting the signed XML. Verify the full feed signature and
# its enclosure signature using Sparkle's own verifier and the same account.
[ -f "$TYPECOUNT_APPCAST" ] || fail 'Sparkle did not generate appcast.xml.'
TYPECOUNT_ITEM_COUNT="$(xmllint --nonet --xpath 'count(/rss/channel/item)' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ENCLOSURE_COUNT="$(xmllint --nonet --xpath 'count(/rss/channel/item/enclosure)' "$TYPECOUNT_APPCAST")"
[ "$TYPECOUNT_ITEM_COUNT" = 1 ] && [ "$TYPECOUNT_ENCLOSURE_COUNT" = 1 ] || fail 'Expected exactly one update item and enclosure.'
TYPECOUNT_ITEM_VERSION="$(xmllint --nonet --xpath 'string(/rss/channel/item/*[local-name()="version"])' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ITEM_SHORT_VERSION="$(xmllint --nonet --xpath 'string(/rss/channel/item/*[local-name()="shortVersionString"])' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ENCLOSURE_URL="$(xmllint --nonet --xpath 'string(/rss/channel/item/enclosure/@url)' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ENCLOSURE_SIGNATURE="$(xmllint --nonet --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ENCLOSURE_LENGTH="$(xmllint --nonet --xpath 'string(/rss/channel/item/enclosure/@length)' "$TYPECOUNT_APPCAST")"
TYPECOUNT_ZIP_LENGTH="$(stat -f '%z' "$TYPECOUNT_ZIP")"
[ "$TYPECOUNT_ITEM_VERSION" = "$TYPECOUNT_BUILD" ] || fail 'The generated build version does not match the app.'
[ "$TYPECOUNT_ITEM_SHORT_VERSION" = "$TYPECOUNT_VERSION" ] || fail 'The generated release version does not match the app.'
[ "$TYPECOUNT_ENCLOSURE_URL" = "$TYPECOUNT_DOWNLOAD_PREFIX$TYPECOUNT_ZIP_NAME" ] || fail 'The generated download URL is incorrect.'
[ -n "$TYPECOUNT_ENCLOSURE_SIGNATURE" ] || fail 'The update archive has no EdDSA signature.'
[ "$TYPECOUNT_ENCLOSURE_LENGTH" = "$TYPECOUNT_ZIP_LENGTH" ] || fail 'The update archive length is incorrect.'
"$TYPECOUNT_TOOLS/sign_update" --account "$TYPECOUNT_ACCOUNT" --verify "$TYPECOUNT_APPCAST"
"$TYPECOUNT_TOOLS/sign_update" --account "$TYPECOUNT_ACCOUNT" --verify "$TYPECOUNT_ZIP" "$TYPECOUNT_ENCLOSURE_SIGNATURE"

(
    cd "$TYPECOUNT_ARCHIVES"
    shasum -a 256 "$TYPECOUNT_ZIP_NAME" appcast.xml > SHA256SUMS.txt
)

# Replace only this generated version's output after every verification passes.
# Other versions, DMGs, and the source app are never scanned or modified.
TYPECOUNT_OUTPUT_STAGE="$TYPECOUNT_STAGE/output"
mkdir -p "$TYPECOUNT_OUTPUT_STAGE"
mv "$TYPECOUNT_ZIP" "$TYPECOUNT_APPCAST" "$TYPECOUNT_ARCHIVES/SHA256SUMS.txt" "$TYPECOUNT_OUTPUT_STAGE/"
TYPECOUNT_DESTINATION="$TYPECOUNT_ROOT/dist/updates/$TYPECOUNT_VERSION"
rm -rf "$TYPECOUNT_DESTINATION"
mv "$TYPECOUNT_OUTPUT_STAGE" "$TYPECOUNT_DESTINATION"
printf '\nCreated signed update artifacts in %s\n' "$TYPECOUNT_DESTINATION"
printf 'Upload %s, appcast.xml, and SHA256SUMS.txt together to GitHub Release v%s.\n' "$TYPECOUNT_ZIP_NAME" "$TYPECOUNT_VERSION"
printf 'Do not edit the signed appcast after generation. No files were uploaded.\n'
