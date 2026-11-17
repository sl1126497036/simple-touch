#!/bin/bash
# Simple Touch 安装脚本：编译 → 生成图标 → 签名 → 安装开机自启
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/Simple Touch.app"
BIN="$APP/Contents/MacOS/SimpleTouch"
PLIST_SRC="$ROOT/com.simpletouch.app.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.simpletouch.app.plist"
DOMAIN="gui/$(id -u)"

echo "==> 1/6 准备 App 目录"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
echo "    完成: $APP"

echo "==> 2/6 编译"
swiftc -O -swift-version 5 -o "$BIN" main.swift SettingsView.swift \
  -framework CoreGraphics -framework AppKit -framework Foundation
echo "    完成: $BIN"

echo "==> 3/6 生成图标"
swift tools/makeicon.swift /tmp/simpletouch_icon.png >/dev/null
rm -rf /tmp/ST.iconset && mkdir -p /tmp/ST.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s /tmp/simpletouch_icon.png --out /tmp/ST.iconset/icon_${s}x${s}.png >/dev/null 2>&1
  d=$((s*2))
  sips -z $d $d /tmp/simpletouch_icon.png --out /tmp/ST.iconset/icon_${s}x${s}@2x.png >/dev/null 2>&1
done
cp /tmp/simpletouch_icon.png /tmp/ST.iconset/icon_512x512@2x.png
iconutil -c icns /tmp/ST.iconset -o "$APP/Contents/Resources/AppIcon.icns"
echo "    完成: $APP/Contents/Resources/AppIcon.icns"

echo "==> 4/6 签名"
# 有本地代码签名证书就用它：指定要求会 pin 到证书公钥，
# 重编译不会改变签名身份，辅助功能授权可以一直保持。
# 没有就用 ad-hoc 签名（每次重建都需要重新授权）。
SIGN_ID="${SIMPLETOUCH_SIGN_ID:-SimpleTouch Self Signed}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_ID" \
    --identifier com.simpletouch.app --timestamp=none "$APP"
  echo "    完成，签名身份：$SIGN_ID"
else
  codesign --force --deep --sign - \
    --identifier com.simpletouch.app --timestamp=none "$APP"
  echo "    完成（ad-hoc，重建后需重新授权辅助功能）"
fi

echo "==> 5/6 安装开机自启"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|$APP|g" "$PLIST_SRC" > "$PLIST_DST"
# 旧版本进程占着同一个触摸设备，先结束再装，否则两个实例会重复触发手势
pkill -f "SimpleTouch.app/Contents/MacOS/SimpleTouch" 2>/dev/null || true
pkill -f "Simple Touch.app/Contents/MacOS/SimpleTouch" 2>/dev/null || true
sleep 0.4
launchctl bootout "$DOMAIN/com.simpletouch.app" 2>/dev/null || true
# 旧版脚本用过 unload -w，会把服务写成禁用状态，bootstrap 之前必须显式打开
launchctl enable "$DOMAIN/com.simpletouch.app" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>/dev/null || launchctl load -w "$PLIST_DST"
echo "    完成: $PLIST_DST"

echo "==> 6/6 启动"
sleep 0.5
launchctl kickstart -k "$DOMAIN/com.simpletouch.app" 2>/dev/null || true
sleep 0.8
# launchd 有时在 GUI 域无法取得授权上下文，改用 open 启动
if ! pgrep -f "Simple Touch.app/Contents/MacOS/SimpleTouch" >/dev/null; then
  open "$APP" 2>/dev/null || true
  sleep 1.2
fi
if pgrep -f "Simple Touch.app/Contents/MacOS/SimpleTouch" >/dev/null; then
  echo "    运行中 (pid $(pgrep -f 'Simple Touch.app/Contents/MacOS/SimpleTouch' | head -1))"
else
  echo "    未启动，见 /tmp/simpletouch-app.log"
fi

echo ""
echo "安装完成。"
echo "  配置文件: ~/.config/simple-touch/config.json"
echo "  运行日志: /tmp/simpletouch-app.log"
echo "  停止服务: launchctl bootout $DOMAIN/com.simpletouch.app"
echo ""
echo "首次安装需在“系统设置 → 隐私与安全性 → 辅助功能”中授权 $APP"
echo "旧版本的 SimpleTouch.app 可删除，两套同时运行会重复触发手势。"
