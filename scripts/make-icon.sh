#!/bin/bash
set -euo pipefail
TYPECOUNT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TYPECOUNT_ICONSET="$TYPECOUNT_ROOT/.build/AppIcon.iconset"
mkdir -p "$TYPECOUNT_ICONSET"
for TYPECOUNT_SIZE in 16 32 128 256 512; do
    sips --resampleHeightWidth "$TYPECOUNT_SIZE" "$TYPECOUNT_SIZE" "$TYPECOUNT_ROOT/Resources/AppIcon.png" --out "$TYPECOUNT_ICONSET/icon_${TYPECOUNT_SIZE}x${TYPECOUNT_SIZE}.png" >/dev/null
    TYPECOUNT_RETINA_SIZE=$((TYPECOUNT_SIZE * 2))
    sips --resampleHeightWidth "$TYPECOUNT_RETINA_SIZE" "$TYPECOUNT_RETINA_SIZE" "$TYPECOUNT_ROOT/Resources/AppIcon.png" --out "$TYPECOUNT_ICONSET/icon_${TYPECOUNT_SIZE}x${TYPECOUNT_SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$TYPECOUNT_ICONSET" --output "$TYPECOUNT_ROOT/Resources/AppIcon.icns"
printf 'Created %s\n' "$TYPECOUNT_ROOT/Resources/AppIcon.icns"
