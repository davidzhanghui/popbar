#!/bin/bash
set -e
cd "$(dirname "$0")"

APP=build.noindex/PopBar.app
mkdir -p build build.noindex

# 先删后增:避免改名/删除的源码或资源在包里留下幽灵文件
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "build/PopBar" Sources/*.swift

cp build/PopBar "$APP/Contents/MacOS/PopBar"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    mkdir -p "$APP/Contents/Resources"
    cp Resources/AppIcon.icns "$APP/Contents/Resources/"
fi
# 优先用自签名证书 "PopBar Dev"(TCC 按证书识别身份,重编译不必重新授权);
# 证书不存在则回退 adhoc 签名
if security find-identity -v -p codesigning | grep -q "PopBar Dev"; then
    codesign --force --sign "PopBar Dev" "$APP"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

codesign --verify --deep --strict "$APP"
echo "Built $APP"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
arch=$(uname -m)
dmg="build/PopBar-${version}-${arch}.dmg"
rm -f "$dmg"   # 同名版本直接覆盖,保证 dmg 与本次构建一致
stage=$(mktemp -d "$PWD/build.noindex/dmg-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT   # 成功/失败都清理暂存目录
ditto "$APP" "$stage/PopBar.app"
ln -s /Applications "$stage/Applications"
hdiutil create -srcfolder "$stage" -volname PopBar -format UDZO "$dmg"
hdiutil verify "$dmg" >/dev/null
echo "Built $dmg"
