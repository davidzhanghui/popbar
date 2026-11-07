#!/bin/bash
# 构建 PopBar.app 与 dmg：SwiftPM 编译（release），再组装 .app、签名、打 dmg。
#
#   ./build.sh            # release 构建 + dmg
#   ./build.sh --debug    # debug 构建（增量快，不打 dmg），供 restart.sh 开发用
set -e
cd "$(dirname "$0")"

CONFIG=release
DMG=1
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug; DMG=0 ;;
        --no-dmg) DMG=0 ;;
        *) echo "未知参数:$arg(可用:--debug / --no-dmg)" >&2; exit 2 ;;
    esac
done

APP=build.noindex/PopBar.app
arch=$(uname -m)

mkdir -p build build.noindex
swift build -c "$CONFIG" --arch "$arch" --product PopBar
BIN=$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/PopBar

# 先删后增:避免改名/删除的资源在包里留下幽灵文件
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopBar"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# 优先用自签名证书 "PopBar Dev"(TCC 按证书识别身份,重编译不必重新授权);
# 证书不存在则回退 adhoc 签名
if security find-identity -v -p codesigning | grep -q "PopBar Dev"; then
    codesign --force --sign "PopBar Dev" "$APP"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG)"

[ "$DMG" = 1 ] || exit 0

# 每次打包前清空产物目录,build/ 里只留下本次 dmg
rm -rf build && mkdir -p build
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
dmg="build/PopBar-${version}-${arch}.dmg"
stage=$(mktemp -d "$PWD/build.noindex/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT   # 成功/失败都清理暂存目录
ditto "$APP" "$stage/PopBar.app"
ln -s /Applications "$stage/Applications"
hdiutil create -srcfolder "$stage" -volname PopBar -format UDZO "$dmg"
hdiutil verify "$dmg" >/dev/null
echo "Built $dmg"
