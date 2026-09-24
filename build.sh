#!/bin/bash
set -e
cd "$(dirname "$0")"

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--dmg" ]; }; then
    echo "Usage: $0 [--dmg]" >&2
    exit 1
fi

APP=build.noindex/PopBar.app
mkdir -p build build.noindex

if [ "${1:-}" != "--dmg" ]; then
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
fi

codesign --verify --deep --strict "$APP"
if [ "${1:-}" != "--dmg" ]; then
    echo "Built $APP"
fi

if [ "${1:-}" = "--dmg" ]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    arch=$(uname -m)
    dmg="build/PopBar-${version}-${arch}.dmg"
    if [ -e "$dmg" ]; then
        echo "Already exists: $dmg (move it before packaging again)" >&2
        exit 1
    fi
    stage=$(mktemp -d "$PWD/build.noindex/dmg-stage.XXXXXX")
    ditto "$APP" "$stage/PopBar.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -srcfolder "$stage" -volname PopBar -format UDZO "$dmg"
    hdiutil verify "$dmg"
    echo "Built $dmg"
fi
