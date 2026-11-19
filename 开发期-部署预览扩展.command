#!/bin/bash
# 一键安装/更新 .cg 的空格预览与 Finder 缩略图扩展
# 用途：Xcode 的工程格式（project.xcproj）无法声明"把 appex 拷进主 App"的阶段，
#       所以扩展构建出来后需要手动嵌一次。改完扩展代码后重新跑本脚本即可。
# 不会修改主 App 的任何源码，也不会动 obj/usdz 等其他格式的预览。

set -e
cd "$(dirname "$0")"

PROJ="3d渲染.xcodeproj"
# 构建产物落在 /tmp：工程内或 ~/Library 下一旦出现第二份 .app，LaunchServices 就会把它
# 也注册成 .cg 的宿主，双击文档时系统可能选中那一份并另起一个实例。/tmp 不在扫描范围，
# 脚本末尾再补一次注销，双保险。
BUILD_ROOT="${BUILD_ROOT:-/tmp/3drender-build}"
APP="$BUILD_ROOT/Debug/3d渲染.app"
INSTALLED="$HOME/Applications/3d渲染.app"
SIGNID="Apple Development: lan_i@outlook.com (W84RPS4XKV)"
# 扩展必须按「开了优化 + 不带 DEBUG 条件」构建，否则空格预览会慢上一个量级：
# 工程里只有 Debug 一个配置，所以直接在命令行覆盖构建设置——
#   SWIFT_OPTIMIZATION_LEVEL=-O  → 不再是 -Onone（大模型解压/建顶点快 10 倍以上）
#   SWIFT_ACTIVE_COMPILATION_CONDITIONS= 清空 → #if DEBUG 里的离屏自检（额外渲一帧 + 写 PNG）
#   整段被编译掉，不会进入正式扩展产物
# 主 App 的构建配置不受影响，仍走 Debug。
EXT_OPT=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule SWIFT_ACTIVE_COMPILATION_CONDITIONS= GCC_OPTIMIZATION_LEVEL=3)
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 默认只更新扩展；改过主 App 源码时用 UPDATE_APP=1 一起更新安装位的主二进制，
# 否则安装位跑的还是旧 App，双击 .cg 的行为不会变。
if [ "${UPDATE_APP:-0}" = "1" ]; then
  echo "0/5 构建主 App（UPDATE_APP=1）…"
  xcodebuild -project "$PROJ" -target 3d渲染 -configuration Debug SYMROOT="$BUILD_ROOT" build CODE_SIGNING_ALLOWED=NO >/dev/null
fi

echo "1/5 构建预览扩展…"
xcodebuild -project "$PROJ" -target CGQuickLook -configuration Debug SYMROOT="$BUILD_ROOT" "${EXT_OPT[@]}" build CODE_SIGNING_ALLOWED=NO >/dev/null

echo "2/5 构建缩略图扩展…"
xcodebuild -project "$PROJ" -target CGQuickLookThumb -configuration Debug SYMROOT="$BUILD_ROOT" "${EXT_OPT[@]}" build CODE_SIGNING_ALLOWED=NO >/dev/null

echo "3/5 只把扩展嵌进已安装 App（构建目录那份一律不留 PlugIns）…"
# 构建目录的 .app 只要带着 PlugIns，LaunchServices 就会把它当第二个宿主，
# 系统设置里于是出现两组「3d渲染 → 快速查看」，同名扩展两份抢着响应。
if [ -d "$APP/Contents/PlugIns" ]; then
    mv "$APP/Contents/PlugIns" "$APP/Contents/PlugIns.off"
fi

# 首次安装才整体复制；要更新主二进制就显式带 UPDATE_APP=1，
# 免得随手跑脚本时拿构建产物把已安装版本降级。
if [ "${UPDATE_APP:-0}" = "1" ] || [ ! -d "$INSTALLED" ]; then
    ditto "$APP" "$INSTALLED"
fi
mkdir -p "$INSTALLED/Contents/PlugIns"
rm -rf "$INSTALLED/Contents/PlugIns/CGQuickLookThumb.appex"   # 清理旧目录名残留
ditto "$BUILD_ROOT/Debug/CGQuickLook.appex" "$INSTALLED/Contents/PlugIns/CGQuickLook.appex"
ditto "$BUILD_ROOT/Debug/CGQuickLookThumb.appex" "$INSTALLED/Contents/PlugIns/CGThumb.appex"

echo "4/5 签名…"
codesign --force --sign "$SIGNID" --entitlements 预览/CG扩展共用.entitlements --timestamp=none "$INSTALLED/Contents/PlugIns/CGQuickLook.appex"
codesign --force --sign "$SIGNID" --entitlements 预览/CG扩展共用.entitlements --timestamp=none "$INSTALLED/Contents/PlugIns/CGThumb.appex"
codesign --force --sign "$SIGNID" --timestamp=none "$INSTALLED"

echo "5/5 注册到系统…"
"$LSREG" -u "$(pwd)/$APP" 2>/dev/null || true
"$LSREG" -u "$BUILD_ROOT/Debug/CGQuickLook.appex" 2>/dev/null || true
"$LSREG" -u "$BUILD_ROOT/Debug/CGQuickLookThumb.appex" 2>/dev/null || true
pluginkit -r "$BUILD_ROOT/Debug/CGQuickLook.appex" 2>/dev/null || true
pluginkit -r "$BUILD_ROOT/Debug/CGQuickLookThumb.appex" 2>/dev/null || true
"$LSREG" -f "$INSTALLED"
pluginkit -a "$INSTALLED/Contents/PlugIns/CGQuickLook.appex"
pluginkit -a "$INSTALLED/Contents/PlugIns/CGThumb.appex"
killall QuickLookUIService 2>/dev/null || true

echo
echo "完成。已注册的扩展："
pluginkit -m -A -v 2>/dev/null | grep -i cgquick || echo "（未查到，需重启 Finder 后再试）"
