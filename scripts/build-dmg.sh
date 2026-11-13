#!/bin/bash
set -euo pipefail
TYPECOUNT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TYPECOUNT_ROOT"
TYPECOUNT_SOURCE="$TYPECOUNT_ROOT/dist/TypeCount.app"
TYPECOUNT_PYTHON="$TYPECOUNT_ROOT/.build/dmg-tools/bin/python"

if [ ! -d "$TYPECOUNT_SOURCE" ]; then
    printf 'Build the universal app first: UNIVERSAL=1 ./scripts/build-app.sh\n' >&2
    exit 1
fi
codesign --verify --strict "$TYPECOUNT_SOURCE"
lipo "$TYPECOUNT_SOURCE/Contents/MacOS/TypeCount" -verify_arch arm64 x86_64
TYPECOUNT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TYPECOUNT_SOURCE/Contents/Info.plist")"
if [[ ! "$TYPECOUNT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Unexpected application version: %s\n' "$TYPECOUNT_VERSION" >&2
    exit 1
fi
if [ ! -x "$TYPECOUNT_PYTHON" ]; then
    python3 -m venv "$TYPECOUNT_ROOT/.build/dmg-tools"
fi
if ! "$TYPECOUNT_PYTHON" -c 'import ds_store' >/dev/null 2>&1; then
    "$TYPECOUNT_PYTHON" -m pip install -r scripts/dmg-requirements.txt
fi

TYPECOUNT_STAGE="$(mktemp -d "$TYPECOUNT_ROOT/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$TYPECOUNT_STAGE"' EXIT
TYPECOUNT_DMG="$TYPECOUNT_ROOT/dist/TypeCount-${TYPECOUNT_VERSION}-macOS-universal.dmg"
ditto "$TYPECOUNT_SOURCE" "$TYPECOUNT_STAGE/字迹.app"
ln -s /Applications "$TYPECOUNT_STAGE/Applications"
cat > "$TYPECOUNT_STAGE/安装说明.txt" <<EOF
字迹 · TypeCount ${TYPECOUNT_VERSION} 测试版

系统要求：macOS 15.6 或以上；支持 Apple Silicon 和 Intel Mac。

安装与首次使用
1. 将「字迹」拖到 Applications（应用程序）文件夹。
2. 弹出此磁盘映像，再从「应用程序」打开字迹。
3. 在字迹的设置中开启辅助功能权限，返回后点「重新检查」。
   辅助功能已包含键盘监听能力，不必重复授权输入监控。

首次打开提示
本包使用本机开发证书签名，尚未使用 Apple Developer ID 签名及公证。
其他 Mac 首次打开时，macOS 可能显示无法验证开发者的提示。
仅在确认来源可信后，按 macOS「系统设置 → 隐私与安全性」提供的
「仍要打开」流程确认；受组织管理的 Mac 可能不允许这样打开。
Apple 说明：https://developer.apple.com/news/?id=saqachfa

统计与隐私
菜单栏默认显示图标，右上角小字展示今日字数（如 1.9k），整体仅占一个图标位置。
悬停可看完整统计，点击查看各 App 明细。设置中可选其他角标或仅图标，并可开启「登录时启动字迹」。
主窗口左上角使用下拉箭头切换「输入统计」和「键鼠活动」，默认展示输入统计。
键鼠活动提供左右点击、小时分布和常用键位。
中文、英文字母和标点按字符统计，忽略空白；删除不扣回累计量。
中文输入法、自动更正和部分编辑器可能存在误差；未提供输入文本的 App 显示「仅按键」。
统计数据仅保存在接收者自己的 Mac，不保存输入原文。
「检查更新」通过 GitHub Releases 获取签名版本列表与更新包，安装后重新启动字迹。
自动检查默认关闭；不上传输入数据，不启用系统画像，安装包替换不删除现有统计。
本安装包不包含开发者的个人统计数据、私钥或签名配置。
EOF
"$TYPECOUNT_PYTHON" scripts/dmg-layout.py "$TYPECOUNT_STAGE"
codesign --verify --strict "$TYPECOUNT_STAGE/字迹.app"
hdiutil create -ov -volname "字迹 ${TYPECOUNT_VERSION}" -srcfolder "$TYPECOUNT_STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$TYPECOUNT_DMG"
hdiutil verify "$TYPECOUNT_DMG"
(
    cd "$TYPECOUNT_ROOT/dist"
    shasum -a 256 "$(basename "$TYPECOUNT_DMG")" > "$(basename "$TYPECOUNT_DMG").sha256"
)
printf '\nCreated %s\n' "$TYPECOUNT_DMG"
printf 'Local development signature only; not Apple-notarized.\n'
