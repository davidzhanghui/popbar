#!/bin/bash
# 构建 PopBar.app 与 dmg：SwiftPM 编译（release），再组装 .app、签名、打 dmg。
# 只有 release 构建（发版）成功后删除 .build 缓存；--debug 构建保留缓存供 restart.sh 增量编译。
#
#   ./build.sh            # release 构建 + dmg
#   ./build.sh --debug    # debug 构建（不打 dmg），供 restart.sh 开发用
#   ARCH=x86_64 ./build.sh     # 为 Intel Mac 交叉编译（默认取本机架构）
#   ARCH=universal ./build.sh  # arm64 + x86_64 通用包
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

# 发版构建成功后清掉 SwiftPM 缓存(.build)：产物已拷进 .app，缓存只是下次增量的加速。
# debug 构建是 restart.sh 的开发循环，保留缓存才能增量编译。
clean_build_cache() {
    [ "$CONFIG" = release ] || return 0
    rm -rf .build
    echo "Cleaned .build"
}

APP=build.noindex/PopBar.app
arch=${ARCH:-$(uname -m)}
case "$arch" in
    universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    arm64|x86_64) ARCH_FLAGS=(--arch "$arch") ;;
    *) echo "不支持的 ARCH:$arch(可用:arm64 / x86_64 / universal)" >&2; exit 2 ;;
esac

mkdir -p build build.noindex
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product PopBar
BIN=$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/PopBar

# 先删后增:避免改名/删除的资源在包里留下幽灵文件
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopBar"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# 签名优先级：
# 1) 显式指定 CODESIGN_IDENTITY（CI 发版通过临时钥匙串传入 SHA-1 指纹，或本地手动指定）
# 2) 本地钥匙串中已信任的统一证书 "ShuLan App Signing"
# 3) 回退 ad-hoc 签名（当 REQUIRE_CODESIGN=1 时禁止回退，防止 CI 静默产出每次掉权限的包）
CODESIGN_ARGS=(--force)
[ -n "${CODESIGN_KEYCHAIN:-}" ] && CODESIGN_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign "${CODESIGN_ARGS[@]}" --sign "$CODESIGN_IDENTITY" "$APP"
elif [ "${REQUIRE_CODESIGN:-0}" = "1" ]; then
    echo "错误: REQUIRE_CODESIGN=1 但未设置 CODESIGN_IDENTITY" >&2
    exit 1
elif security find-identity -v -p codesigning | grep -q '"ShuLan App Signing"'; then
    codesign "${CODESIGN_ARGS[@]}" --sign "ShuLan App Signing" "$APP"
else
    codesign --force --sign - "$APP" 2>/dev/null || true
fi
codesign --verify --deep --strict "$APP"
if [ "${REQUIRE_CODESIGN:-0}" = "1" ]; then
    req=$(codesign -d -r - "$APP" 2>&1)
    if echo "$req" | grep -q "cdhash" || ! echo "$req" | grep -q 'identifier "dev.popbar.app"'; then
        echo "错误: 签名结果未绑定固定证书，拒绝发版: $req" >&2
        exit 1
    fi
fi
echo "Built $APP ($CONFIG)"

# 构建成功后清掉 SwiftPM 缓存(仅 release)
if [ "$DMG" = 0 ]; then
    clean_build_cache
    exit 0
fi

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

clean_build_cache
