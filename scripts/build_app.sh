#!/bin/zsh
# 编译并打包 dist/FingerPath.app。
# 用法：zsh scripts/build_app.sh            （默认临时签名 ad-hoc）
#      SIGN_IDENTITY="你的证书名" zsh scripts/build_app.sh   （固定签名，重新编译后不用重新授权辅助功能）
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/FingerPath.app"
cd "$ROOT"

# 命令行工具自带的 macOS 27 SDK 缺少 SwiftUI 宏插件；有 26.5 SDK 时优先用它。装了完整 Xcode 可删掉这段。
LEGACY_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ -z "${SDKROOT:-}" && -d "$LEGACY_SDK" ]]; then
  export SDKROOT="$LEGACY_SDK"
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/FingerPath" "$APP/Contents/MacOS/FingerPath"
cp "$ROOT/AppResources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppResources/FingerPath.icns" "$APP/Contents/Resources/FingerPath.icns"

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"
echo "$APP"
