#!/bin/bash
# PopBar 测试入口,做两件事:
#
# 1. 纯逻辑测试:swiftc 编译 Sources(去掉应用入口 main.swift)+ tests/main.swift,
#    生成 build/popbar-tests 并运行。POPBAR_CONFIG_DIR 指向临时目录,避免读写真实配置。
# 2. 弹窗可见性静态检查:PopBar 是 accessory(LSUIElement)应用,平时没有前台身份,
#    自建窗口即使 makeKeyAndOrderFront 也会被当前前台 App 盖住,runModal 还会阻塞主线程。
#    所以对每个 runModal()/makeKeyAndOrderFront( 调用点,回看前 30 行必须出现
#    activateForUI();sheet(beginSheetModal)挂在已在前台的窗口上,不检查。
#
# 任一步骤失败退出码非 0。
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/popbar-tests $(ls Sources/*.swift | grep -v '/main.swift$') tests/main.swift
POPBAR_CONFIG_DIR=$(mktemp -d) ./build/popbar-tests

echo ""
echo "[弹窗可见性]"
fail=0
while IFS= read -r hit; do
    file=${hit%%:*}
    line=$(echo "$hit" | cut -d: -f2)
    start=$((line - 30))
    [ "$start" -lt 1 ] && start=1
    if sed -n "${start},${line}p" "$file" | grep -q "activateForUI()"; then
        echo "  ✓ $file:$line"
    else
        echo "  ✗ $file:$line 显示前缺少 NSApp.activateForUI()"
        sed -n "${line}p" "$file" | sed 's/^/        /'
        fail=1
    fi
done < <(grep -n "runModal()\|makeKeyAndOrderFront(" Sources/*.swift \
         | grep -v "func " | grep -v "///" | grep -v "activateForUI")

if [ "$fail" = 0 ]; then
    echo "弹窗检查通过:所有窗口/弹窗显示前都已激活到前台"
else
    echo "弹窗检查失败:上面列出的调用点会被前台 App 的窗口盖住"
fi
exit $fail
