#!/bin/zsh
# 编译、安装到 /Applications 并启动。
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/scripts/build_app.sh"
pkill -x FingerPath 2>/dev/null || true
/usr/bin/ditto "$ROOT/dist/FingerPath.app" "/Applications/FingerPath.app"
open "/Applications/FingerPath.app"
echo "已安装并启动 /Applications/FingerPath.app"
echo "第一次运行：系统设置 → 隐私与安全性 → 辅助功能，打开 FingerPath。"
