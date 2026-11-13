# Third-party notices

TypeCount's own source code is distributed under the [MIT License](LICENSE).

## Sparkle 2.10.1

The app embeds [Sparkle](https://github.com/sparkle-project/Sparkle/tree/2.10.1) for checking, verifying, and installing updates. Sparkle is distributed under its [upstream license and included third-party notices](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE).

The build script copies the complete upstream license into every packaged app at `Contents/Resources/Sparkle-LICENSE.txt`. The framework, helpers, and license are obtained from the checksum-verified Swift Package Manager binary artifact pinned in `Package.resolved`.

## DMG build tools

[ds-store](https://github.com/al45tair/ds_store) and its dependency [mac_alias](https://github.com/al45tair/mac_alias) are used only to arrange the DMG's Finder layout. They are installed in the ignored `.build/dmg-tools` environment and are not distributed inside the app.
