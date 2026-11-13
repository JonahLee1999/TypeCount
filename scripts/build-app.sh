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

TYPECOUNT_APP="$TYPECOUNT_ROOT/dist/TypeCount.app"
mkdir -p "$TYPECOUNT_APP/Contents/MacOS" "$TYPECOUNT_APP/Contents/Resources"
cp "$TYPECOUNT_BIN_DIR/TypeCount" "$TYPECOUNT_APP/Contents/MacOS/TypeCount"
cp Resources/Info.plist "$TYPECOUNT_APP/Contents/Info.plist"
cp "$TYPECOUNT_ICON" "$TYPECOUNT_APP/Contents/Resources/AppIcon.icns"
chmod +x "$TYPECOUNT_APP/Contents/MacOS/TypeCount"
# Local signing only; a distribution release also needs Developer ID and notarization.
codesign --force --sign "$TYPECOUNT_SIGN_IDENTITY" --timestamp=none "$TYPECOUNT_APP"
codesign --verify --strict "$TYPECOUNT_APP"
printf '\nBuilt %s\n' "$TYPECOUNT_APP"
