#!/bin/bash
# 打包发行版：构建主 App + 两个 Quick Look 扩展，把扩展嵌进 Contents/PlugIns，
# 分层签名后输出到 dist/，产出物自带 .cg 的空格预览与 Finder 缩略图。
#
# 为什么需要它：本工程的 project.xcproj（folder 同步新格式）不支持 copy-files /
# run-script 构建阶段，Xcode 不会把 appex 嵌进 App，必须在这里补一刀。
#
# 用法：双击，或 bash 发行-打包签名公证.command [Release|Debug]

set -e
cd "$(dirname "$0")"

CONFIG="${1:-Release}"
PROJ="3d渲染.xcodeproj"
APP_NAME="3d渲染"
ENTITLEMENTS="预览/CG扩展共用.entitlements"
# 发行给他人时把下面这行换成 Developer ID Application 证书的名字
SIGNID="Apple Development: lan_i@outlook.com (W84RPS4XKV)"
DIST="dist"
STAGE="$DIST/$APP_NAME.app"

LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 公证必需 hardened runtime + 可信时间戳；本机自测想跑快些可 HARDENED=0
HARDENED="${HARDENED:-1}"
# 公证用钥匙串里的凭据名，先用下面命令存一次（只需一次）：
#   xcrun notarytool store-credentials "3drender" --apple-id <你的AppleID> --team-id FK69425PTP --password <App专用密码>
# 留空则跳过公证步骤
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ "$HARDENED" = "1" ]; then
  SIGN_FLAGS=(--options runtime --timestamp)
else
  SIGN_FLAGS=(--timestamp=none)
fi

echo "== 1/6 构建（$CONFIG）"
xcodebuild -project "$PROJ" -target "$APP_NAME"        -configuration "$CONFIG" SYMROOT="$BUILD_ROOT" build CODE_SIGNING_ALLOWED=NO >/dev/null
xcodebuild -project "$PROJ" -target CGQuickLook        -configuration "$CONFIG" SYMROOT="$BUILD_ROOT" build CODE_SIGNING_ALLOWED=NO >/dev/null
xcodebuild -project "$PROJ" -target CGQuickLookThumb   -configuration "$CONFIG" SYMROOT="$BUILD_ROOT" build CODE_SIGNING_ALLOWED=NO >/dev/null

BUILD_ROOT="${BUILD_ROOT:-/tmp/3drender-build}"
BUILT="$BUILD_ROOT/$CONFIG"

echo "== 2/6 组装 dist/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$DIST"
ditto "$BUILT/$APP_NAME.app" "$STAGE"
rm -rf "$STAGE/Contents/PlugIns"
# 构建目录那份 App 里的 PlugIns 被安装脚本改名成了 PlugIns.off，别带进发行包，
# 否则 codesign --deep 会报 bundle format unrecognized
rm -rf "$STAGE/Contents/PlugIns.off"
mkdir -p "$STAGE/Contents/PlugIns"
ditto "$BUILT/CGQuickLook.appex"      "$STAGE/Contents/PlugIns/CGQuickLook.appex"
# 缩略图扩展沿用 CGThumb.appex 这个目录名（与既有安装保持一致，避免旧副本残留）
ditto "$BUILT/CGQuickLookThumb.appex" "$STAGE/Contents/PlugIns/CGThumb.appex"

echo "== 3/6 分层签名（扩展先签，主 App 后签）"
codesign --force --sign "$SIGNID" --entitlements "$ENTITLEMENTS" "${SIGN_FLAGS[@]}" "$STAGE/Contents/PlugIns/CGQuickLook.appex"
codesign --force --sign "$SIGNID" --entitlements "$ENTITLEMENTS" "${SIGN_FLAGS[@]}" "$STAGE/Contents/PlugIns/CGThumb.appex"
codesign --force --sign "$SIGNID" "${SIGN_FLAGS[@]}" "$STAGE"

echo "== 4/6 校验"
codesign --verify --deep --strict --verbose=2 "$STAGE" 2>&1 | tail -3
for a in CGQuickLook CGThumb; do
  if codesign -d --entitlements :- "$STAGE/Contents/PlugIns/$a.appex" 2>/dev/null | grep -q "app-sandbox"; then
    printf '   %-14s app-sandbox=开\n' "$a"
  else
    printf '   %-14s app-sandbox=缺失（扩展不会被加载）\n' "$a"
  fi
done
if ! spctl --assess --type execute "$STAGE" 2>/dev/null; then
  echo "   ⚠ Gatekeeper 未通过：缺少 Developer ID 证书与公证（本机自用无碍，发给他人的话需补）"
fi

echo "== 5/6 打 zip"
ZIP="$DIST/$APP_NAME-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Contents/Info.plist" 2>/dev/null || echo 1.0)-$CONFIG.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "== 6/6 提交公证（这一步要等几分钟）"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$STAGE"
  xcrun stapler validate "$STAGE"
  # staple 之后票据在 App 里，zip 必须重打才能带上
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
else
  echo "== 6/6 跳过公证（未设置 NOTARY_PROFILE）"
  echo "   发行给他人前先跑一次：xcrun notarytool store-credentials \"3drender\" --apple-id <AppleID> --team-id FK69425PTP --password <App专用密码>"
  echo "   然后：NOTARY_PROFILE=3drender bash 发行-打包签名公证.command"
fi

"$LSREG" -u "$PWD/$STAGE" 2>/dev/null || true

echo
echo "完成："
echo "  $PWD/$STAGE"
echo "  $PWD/$ZIP"
echo "扩展清单："
ls -1 "$STAGE/Contents/PlugIns"
