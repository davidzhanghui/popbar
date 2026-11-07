#!/bin/bash
# PopBar 测试入口：
#
# 1. 逻辑测试：`swift test`（PopBarCoreTests + 迁移自老 tests/main.swift 的 851 项检查）。
#    POPBAR_CONFIG_DIR 由测试自己指向临时目录，不读写真实配置。
#    传 --static-only 跳过这一步（CI 里 swift test 单独跑）。
# 2. 静态检查（逐条列出命中行，任一失败退出码非 0）：
#    a. 弹窗可见性：PopBar 是 accessory(LSUIElement)应用,平时没有前台身份,
#       自建窗口即使 makeKeyAndOrderFront 也会被当前前台 App 盖住,runModal 还会阻塞主线程。
#       所以每个 runModal()/makeKeyAndOrderFront( 调用点,回看前 30 行必须出现 activateForUI()。
#       有意不激活的调用点（截屏遮罩等 nonactivating 面板，见 v2.5.1 的闪屏修复）在同一行或上一行
#       写 `// popbar:no-activate` 豁免。
#    b. 子进程：Sources 里除 PopBarCore/Shell.swift 外不允许出现 `Process()`。
#    c. 文案：L10n.t("…" 的中文参数里不允许出现「中文字符 + 半角标点」（，。：；！？）。
set -e
cd "$(dirname "$0")/.."

STATIC_ONLY=0
[ "$1" = "--static-only" ] && STATIC_ONLY=1

if [ "$STATIC_ONLY" = 0 ]; then
    swift test 2>&1 | tee build.noindex/swift-test.log | grep -E "✗|error:|failed|合计|Executed .* tests" || true
    if grep -qE "with [1-9][0-9]* failures|error:" build.noindex/swift-test.log; then
        echo "swift test 失败,详见 build.noindex/swift-test.log"
        exit 1
    fi
fi

fail=0

echo ""
echo "[弹窗可见性]"
while IFS= read -r hit; do
    file=${hit%%:*}
    line=$(echo "$hit" | cut -d: -f2)
    prev=$((line - 1))
    if sed -n "${prev},${line}p" "$file" | grep -q "popbar:no-activate"; then
        echo "  ○ $file:$line(popbar:no-activate)"
        continue
    fi
    start=$((line - 30))
    [ "$start" -lt 1 ] && start=1
    if sed -n "${start},${line}p" "$file" | grep -q "activateForUI()"; then
        echo "  ✓ $file:$line"
    else
        echo "  ✗ $file:$line 显示前缺少 NSApp.activateForUI()(有意不激活请加 // popbar:no-activate)"
        sed -n "${line}p" "$file" | sed 's/^/        /'
        fail=1
    fi
done < <(grep -rn "runModal()\|makeKeyAndOrderFront(" Sources --include=*.swift \
         | grep -v "func " | grep -v "///" | grep -v "activateForUI")

echo ""
echo "[子进程只走 Shell]"
hits=$(grep -rn "Process()" Sources --include=*.swift | grep -v "^Sources/PopBarCore/Shell.swift:" || true)
if [ -n "$hits" ]; then
    echo "$hits" | sed 's/^/  ✗ /'
    echo "  以上位置直接创建了 Process,请改用 PopBarCore.Shell"
    fail=1
else
    echo "  ✓ 只有 PopBarCore/Shell.swift 创建子进程"
fi

echo ""
echo "[中文全角标点]"
if ! python3 tests/check_punct.py Sources; then fail=1; fi

echo ""
if [ "$fail" = 0 ]; then
    echo "静态检查全部通过"
else
    echo "静态检查失败:见上面 ✗ 行"
fi
exit $fail
