#!/bin/bash
# 重启 PopBar:杀掉在跑的实例 → (默认)重新构建 → 启动开发副本 build.noindex/PopBar.app
#
#   ./restart.sh              # 构建 + 重启
#   ./restart.sh --no-build   # 只重启(没改代码时用)
#   ./restart.sh --fg         # 前台运行,日志直接打在终端里(Ctrl+C 退出)
set -e
cd "$(dirname "$0")"

APP=build.noindex/PopBar.app
BUILD=1
FG=0

for arg in "$@"; do
    case "$arg" in
        --no-build|-n) BUILD=0 ;;
        --fg|--foreground|-f) FG=1 ;;
        -h|--help)
            sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "未知参数:$arg(可用:--no-build / --fg / --help)" >&2; exit 2 ;;
    esac
done

# 1) 杀掉旧实例:按 App 完整路径匹配,不会误伤其它程序
if pgrep -f "$APP" >/dev/null; then
    echo "Stopping running PopBar…"
    pkill -f "$APP" || true
    for _ in $(seq 1 20); do          # 最多等 2s 让它自己退出
        pgrep -f "$APP" >/dev/null || break
        sleep 0.1
    done
    if pgrep -f "$APP" >/dev/null; then
        pkill -9 -f "$APP" || true    # 还赖着就强杀
        sleep 0.3
    fi
fi

# 2) 构建(改过源码才需要;--no-build 跳过)
if [ "$BUILD" = 1 ]; then
    ./build.sh
fi

[ -x "$APP/Contents/MacOS/PopBar" ] || {
    echo "找不到 $APP,先跑一次 ./build.sh" >&2
    exit 1
}

# 3) 启动
if [ "$FG" = 1 ]; then
    echo "Running in foreground (Ctrl+C to quit)…"
    exec "$APP/Contents/MacOS/PopBar"
fi

open "$APP"
for _ in $(seq 1 30); do              # 等它起来再报 PID
    pid=$(pgrep -f "$APP" || true)
    [ -n "$pid" ] && { echo "PopBar running (pid $pid)"; exit 0; }
    sleep 0.1
done
echo "启动后没等到进程,检查辅助功能权限或改用 ./restart.sh --fg 看日志" >&2
exit 1
