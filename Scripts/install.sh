#!/bin/zsh
# 构建 Debug 版并安装到 /Applications，刷新 Quick Look 注册。不重启 Finder。
set -euo pipefail

ROOT=${0:A:h:h}
APP_NAME=PeekBox.app
BUILD_DIR="$ROOT/build/DerivedData"
PRODUCT="$BUILD_DIR/Build/Products/Debug/$APP_NAME"
DEST="/Applications/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

cd "$ROOT"
# 第三方库不提交仓库，缺失时先构建
[[ -d Packages/PeekCore/Vendor/libzip.xcframework ]] || ./Scripts/build-libzip.sh
[[ -d Packages/PeekCore/Vendor/XADMaster.xcframework ]] || ./Scripts/build-xadmaster.sh
[[ -d Packages/PeekCore/Vendor/CSevenZip.xcframework ]] || ./Scripts/build-7zip.sh
./Scripts/generate-project.sh

xcodebuild -project PeekBox.xcodeproj -scheme PeekBox -configuration Debug \
  -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS,arch=arm64' \
  build -quiet

# 免费团队约束：产物中不得出现描述文件
if find "$PRODUCT" -name embedded.provisionprofile | grep -q .; then
  echo "错误：产物中包含 embedded.provisionprofile" >&2
  exit 1
fi

pkill -x PeekBox 2>/dev/null || true
pkill -x PeekBoxBroker 2>/dev/null || true
# 系统会缓存扩展进程，不结束则仍运行旧代码与旧 entitlement
pkill -x FolderPreview 2>/dev/null || true
pkill -x ArchivePreview 2>/dev/null || true

rm -rf "$DEST"
ditto "$PRODUCT" "$DEST"

# 只保留 /Applications 这一份：构建目录（本脚本的、Xcode 的）和安装中间产物里的副本带着同 ID 的扩展，
# 系统可能启用它们，预览运行的就不是刚安装的代码；peekbox: 链接也可能被交给它们。只注销登记，不删除文件
EXTENSION_IDS=(com.mars.PeekBox.FolderPreview com.mars.PeekBox.ArchivePreview)
for id in $EXTENSION_IDS; do
  pluginkit -m -A -D -v -i "$id" 2>/dev/null | awk -F'\t' 'NF > 1 { print $NF }' | while read -r ext; do
    [[ "$ext" == "$DEST"/* ]] || pluginkit -r "$ext" 2>/dev/null || true
  done
done
"$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *\(.*PeekBox[^/]*\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u | while read -r app; do
  [[ "$app" == "$DEST" || "$app" == "$DEST"/* ]] || "$LSREGISTER" -u "$app" 2>/dev/null || true
done

"$LSREGISTER" -f -R -trusted "$DEST"
for ext in "$DEST"/Contents/PlugIns/*.appex; do
  pluginkit -a "$ext"
done
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1

# 确认系统启用的确实是刚安装的扩展
for id in $EXTENSION_IDS; do
  active=""
  for attempt in 1 2 3 4 5; do
    active=$(pluginkit -m -v -i "$id" 2>/dev/null | awk -F'\t' 'NF > 1 { print $NF; exit }')
    [[ "$active" == "$DEST"/* ]] && break
    sleep 1
  done
  if [[ "$active" != "$DEST"/* ]]; then
    echo "错误：$id 启用的不是刚安装的版本：${active:-（未启用）}" >&2
    exit 1
  fi
done

# 后台服务的位置或启动配置变化后，需由主应用重新注册（见 App/BrokerRegistration.swift）
"$DEST/Contents/MacOS/PeekBox" --refresh-broker >/dev/null 2>&1 || true

echo "已安装：$DEST（预览扩展已确认使用此版本）"
