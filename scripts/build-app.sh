#!/bin/bash
set -euo pipefail
TYPECOUNT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TYPECOUNT_ROOT"

TYPECOUNT_ICON="$TYPECOUNT_ROOT/Resources/AppIcon.icns"
if [ ! -f "$TYPECOUNT_ICON" ]; then
    printf 'Missing app icon: %s\nGenerate Resources/AppIcon.icns before building.\n' "$TYPECOUNT_ICON" >&2
    exit 1
fi

# A configured signing identity keeps local privacy permissions stable across builds.
TYPECOUNT_SIGNING_FILE="$TYPECOUNT_ROOT/.signing-identity"
if [ "${SIGN_IDENTITY+x}" = "x" ]; then
    if [ -z "$SIGN_IDENTITY" ]; then
        printf 'SIGN_IDENTITY is set but empty. Provide a signing identity or unset it.\n' >&2
        exit 1
    fi
    TYPECOUNT_SIGN_IDENTITY="$SIGN_IDENTITY"
elif [ -e "$TYPECOUNT_SIGNING_FILE" ]; then
    if [ ! -f "$TYPECOUNT_SIGNING_FILE" ] || [ ! -r "$TYPECOUNT_SIGNING_FILE" ]; then
        printf 'Cannot read signing identity file: %s\n' "$TYPECOUNT_SIGNING_FILE" >&2
        exit 1
    fi
    TYPECOUNT_SIGN_IDENTITY="$(cat "$TYPECOUNT_SIGNING_FILE")"
    if [[ ! "$TYPECOUNT_SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf 'Invalid %s: expected one nonempty SHA-1 fingerprint (40 hexadecimal characters).\n' "$TYPECOUNT_SIGNING_FILE" >&2
        exit 1
    fi
else
    TYPECOUNT_SIGN_IDENTITY="-"
fi

if [ "$TYPECOUNT_SIGN_IDENTITY" = "-" ]; then
    printf 'Warning: using temporary ad-hoc signing for development; rebuilt apps may require privacy permissions again.\nSet SIGN_IDENTITY or .signing-identity for a stable local identity.\n' >&2
fi

# Host architecture by default. UNIVERSAL=1 builds Apple Silicon + Intel.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    TYPECOUNT_BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release
    TYPECOUNT_BIN_DIR="$(swift build -c release --show-bin-path)"
fi

TYPECOUNT_SPARKLE_ARTIFACT="$TYPECOUNT_ROOT/.build/artifacts/sparkle/Sparkle"
TYPECOUNT_SPARKLE_SOURCE="$TYPECOUNT_SPARKLE_ARTIFACT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$TYPECOUNT_SPARKLE_SOURCE" ] || [ ! -f "$TYPECOUNT_SPARKLE_ARTIFACT/LICENSE" ]; then
    printf 'Missing resolved Sparkle framework or license at %s\nRun swift package resolve and retry.\n' "$TYPECOUNT_SPARKLE_ARTIFACT" >&2
    exit 1
fi

TYPECOUNT_APP="$TYPECOUNT_ROOT/dist/TypeCount.app"
TYPECOUNT_SPARKLE="$TYPECOUNT_APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$TYPECOUNT_APP/Contents/MacOS" "$TYPECOUNT_APP/Contents/Resources" "$TYPECOUNT_APP/Contents/Frameworks"
cp "$TYPECOUNT_BIN_DIR/TypeCount" "$TYPECOUNT_APP/Contents/MacOS/TypeCount"
cp Resources/Info.plist "$TYPECOUNT_APP/Contents/Info.plist"
cp "$TYPECOUNT_ICON" "$TYPECOUNT_APP/Contents/Resources/AppIcon.icns"
cp "$TYPECOUNT_SPARKLE_ARTIFACT/LICENSE" "$TYPECOUNT_APP/Contents/Resources/Sparkle-LICENSE.txt"
# Copy the complete official framework, including its versioned symlinks and helpers.
# Remove only the prior generated framework to avoid retaining files from an older version.
rm -rf "$TYPECOUNT_SPARKLE"
ditto "$TYPECOUNT_SPARKLE_SOURCE" "$TYPECOUNT_SPARKLE"
chmod +x "$TYPECOUNT_APP/Contents/MacOS/TypeCount"

# Manual packaging must re-sign Sparkle from the inside out. The Downloader's
# entitlements must be preserved; --deep is deliberately not used for signing.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
TYPECOUNT_SPARKLE_VERSION="$TYPECOUNT_SPARKLE/Versions/Current"
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none --options runtime \
    "$TYPECOUNT_SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none --options runtime \
    --preserve-metadata=entitlements "$TYPECOUNT_SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none --options runtime \
    "$TYPECOUNT_SPARKLE_VERSION/Autoupdate"
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none --options runtime \
    "$TYPECOUNT_SPARKLE_VERSION/Updater.app"
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none --options runtime "$TYPECOUNT_SPARKLE"
# Local signing only; a distribution release also needs Developer ID and notarization.
# Keep the host's existing local signing identity and do not enable library validation.
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none "$TYPECOUNT_APP"
codesign --verify --deep --strict "$TYPECOUNT_APP"
printf '\nBuilt %s\n' "$TYPECOUNT_APP"
