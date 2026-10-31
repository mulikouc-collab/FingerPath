#!/bin/zsh
# 打包发布用的 zip：通用二进制（Apple 芯片 + Intel）、临时签名。
# 用法：zsh scripts/package_release.sh  → dist/FingerPath-<版本>-macOS.zip
set -euo pipefail
ROOT="${0:A:h:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/AppResources/Info.plist")"
UNIVERSAL=1 SIGN_IDENTITY="-" "$ROOT/scripts/build_app.sh" >/dev/null
ZIP="$ROOT/dist/FingerPath-$VERSION-macOS.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$ROOT/dist/FingerPath.app" "$ZIP"
shasum -a 256 "$ZIP"
