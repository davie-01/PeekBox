#!/bin/zsh
# 构建指定版本的 Release 包，做交付检查，生成 Sparkle 签名与 appcast。
# 用法：Scripts/release.sh <版本号> <构建号> [下载地址前缀]
#   例：Scripts/release.sh 0.1.1 2
#       Scripts/release.sh 0.1.1 2 http://localhost:8765/     （本机测试更新）
#   SKIP_APPCAST=1 时只构建与检查，不打包、不签名（签名需读取钥匙串中的私钥）
# 更新说明：docs/发布说明/<版本号>.md（必需），内嵌进 appcast，检查到更新时显示在更新提示里
# 产物：build/releases/<版本号>/PeekBox-<版本号>.zip 与 appcast.xml（只含这一个版本），
#       以及只留本机的 PeekBox-<版本号>-dSYMs.zip（符号化崩溃日志用，不上传）
# 规则：Debug 版（install.sh）照常构建；发布包在本脚本中做瘦身（去除符号、死代码裁剪、资源按体积优化），
#       交付检查确认已瘦身
# 发布：在 https://github.com/davie-01/Peekbox 新建标签为 v<版本号> 的 Release，上传这两个文件并设为 Latest。
#       应用的 SUFeedURL 指向 releases/latest/download/appcast.xml，即最新一个 Release 的 appcast.xml
set -euo pipefail

VERSION=${1:?缺少版本号}
BUILD=${2:?缺少构建号}
URL_PREFIX=${3:-https://github.com/davie-01/Peekbox/releases/download/v$VERSION/}

ROOT=${0:A:h:h}
DERIVED="$ROOT/build/release-derived"
# 每个版本单独一个目录：appcast 只写这一个版本，下载前缀不会错套到其他版本上
OUT="$ROOT/build/releases/$VERSION"
SPARKLE_BIN="$ROOT/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
NOTES="$ROOT/docs/发布说明/$VERSION.md"

cd "$ROOT"
# 先检查更新说明，避免构建完才发现缺失
[[ "${SKIP_APPCAST:-0}" == 1 || -s "$NOTES" ]] || { echo "错误：缺少更新说明 $NOTES" >&2; exit 1; }
[[ -d Packages/PeekCore/Vendor/libzip.xcframework ]] || ./Scripts/build-libzip.sh
[[ -d Packages/PeekCore/Vendor/XADMaster.xcframework ]] || ./Scripts/build-xadmaster.sh
[[ -d Packages/PeekCore/Vendor/CSevenZip.xcframework ]] || ./Scripts/build-7zip.sh
./Scripts/generate-project.sh
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  xcodebuild -resolvePackageDependencies -project PeekBox.xcodeproj -scheme PeekBox \
    -derivedDataPath "$ROOT/build/DerivedData" -quiet
fi

# 发布包瘦身（只在这里做，Debug 版照常构建）：在命令行给出，对工程 target 与 Swift 包 target 同样生效
# - DEPLOYMENT_POSTPROCESSING：xcodebuild build 默认为 NO，STRIP_INSTALLED_PRODUCT 不起作用，二进制带着全部调试符号；
#   打开后链接产物在签名前去除符号（调试信息先由 dsymutil 存入 dSYM，见下方保存）
# - DEAD_CODE_STRIPPING：链接时去掉未被引用的代码
# - ASSETCATALOG_COMPILER_OPTIMIZATION=space：资源目录按体积优先编译
xcodebuild -project PeekBox.xcodeproj -scheme PeekBox -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  DEPLOYMENT_POSTPROCESSING=YES DEAD_CODE_STRIPPING=YES ASSETCATALOG_COMPILER_OPTIMIZATION=space \
  build -quiet

APP="$DERIVED/Build/Products/Release/PeekBox.app"
# 增量构建不会更新应用包目录本身的修改时间，打包与 Sparkle 安装又原样保留：系统图标缓存据此认为应用没变，
# 用户更新后可能仍显示旧版图标。更新包目录的时间（不影响代码签名）
touch "$APP"
if find "$APP" -name embedded.provisionprofile | grep -q .; then
  echo "错误：产物中包含 embedded.provisionprofile" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

# 交付检查：不得混入 Debug / 预览专用产物；图标已编译；后台服务位于 Helpers 且复用主应用的框架；附带许可原文
fail() { echo "错误：$1" >&2; exit 1; }
if find "$APP" \( -name "*.debug.dylib" -o -name "__preview.dylib" -o -name "*.dSYM" \) | grep -q .; then
  find "$APP" \( -name "*.debug.dylib" -o -name "__preview.dylib" -o -name "*.dSYM" \) >&2
  fail "产物中包含 Debug 专用文件"
fi
# 先取完整输出再查找：在 pipefail 下 grep -q 提前退出会让 assetutil 因管道关闭而失败，检查时好时坏
ASSETS=$(xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null || true)
[[ "$ASSETS" == *'"Name" : "AppIcon"'* ]] || fail "Assets.car 中没有 AppIcon（图标未编译，见 Scripts/generate-project.sh）"
BROKER="$APP/Contents/Helpers/PeekBoxBroker.app"
[[ -x "$BROKER/Contents/MacOS/PeekBoxBroker" ]] || fail "缺少后台服务 $BROKER"
for framework in XADMaster UniversalDetector CSevenZip PeekCore PeekUI; do
  [[ -d "$APP/Contents/Frameworks/$framework.framework" ]] || fail "主应用缺少 $framework.framework"
  [[ ! -d "$BROKER/Contents/Frameworks/$framework.framework" ]] || fail "后台服务仍自带重复的 $framework"
done
# PeekCore / PeekUI 只在主应用 Frameworks 中有一份，扩展与后台服务既不自带、也不再静态链入
for bundle in "$APP"/Contents/PlugIns/*.appex "$BROKER"; do
  [[ ! -d "$bundle/Contents/Frameworks" ]] || fail "$bundle 自带了 Frameworks：$(ls "$bundle/Contents/Frameworks")"
done
for binary in "$APP"/Contents/PlugIns/*.appex/Contents/MacOS/* "$BROKER/Contents/MacOS/PeekBoxBroker" "$APP/Contents/MacOS/PeekBox"; do
  otool -L "$binary" | grep -q '@rpath/PeekCore.framework' || fail "$binary 没有动态链接 PeekCore（可能被静态链入）"
done
# 每个可执行文件依赖的 @rpath 库都能按 rpath 找到，避免运行时加载失败。
# 框架被加载时 dyld 还会沿用加载方可执行文件的 rpath，由第二个及以后的参数给出
check_rpaths() {
  local binary=$1 dir=${1:h} lib found rpath
  local -a rpaths=(${(f)"$(otool -l "$binary" | awk '/LC_RPATH/{getline; getline; print $2}')"} "${@:2}")
  local self=$(otool -D "$binary" | awk 'NR>1{print $1}')   # 框架自身的 install name，不是依赖
  for lib in ${(f)"$(otool -L "$binary" | awk 'NR>1 && $1 ~ /^@rpath\//{print $1}')"}; do
    [[ "$lib" == "$self" ]] && continue
    found=0
    for rpath in $rpaths; do
      rpath=${rpath/@executable_path/$EXEC_DIR}
      rpath=${rpath/@loader_path/$dir}
      [[ -e "$rpath/${lib#@rpath/}" ]] && { found=1; break; }
    done
    (( found )) || fail "$binary 找不到依赖 $lib"
  done
}
for binary in "$APP/Contents/MacOS/PeekBox" "$APP"/Contents/PlugIns/*.appex/Contents/MacOS/* "$BROKER/Contents/MacOS/PeekBoxBroker"; do
  EXEC_DIR=${binary:h} check_rpaths "$binary"
done
for framework in "$APP"/Contents/Frameworks/{PeekCore,PeekUI,XADMaster,CSevenZip}.framework; do
  EXEC_DIR="$APP/Contents/MacOS" check_rpaths "$framework/Versions/A/${framework:t:r}" '@executable_path/../Frameworks'
done
# 发布包已瘦身：自己的二进制不含调试符号（N_STAB）；第三方库只保留导出符号
for binary in "$APP/Contents/MacOS/PeekBox" "$APP"/Contents/PlugIns/*.appex/Contents/MacOS/* \
    "$BROKER/Contents/MacOS/PeekBoxBroker" "$APP"/Contents/Frameworks/{PeekCore,PeekUI}.framework/Versions/A/*(.); do
  (( $(xcrun nm -a "$binary" 2>/dev/null | grep -c ' - ') <= 1 )) || fail "$binary 仍含调试符号（未去除符号）"
done
# 7-Zip 的读取代码只应存在于共享框架中，不得再静态链进扩展或后台服务
for binary in "$APP"/Contents/PlugIns/*.appex/Contents/MacOS/* "$BROKER/Contents/MacOS/PeekBoxBroker"; do
  ! xcrun nm -U "$binary" 2>/dev/null | grep -q '_psz_open' || fail "$binary 中静态链入了 7-Zip"
done
for license in LICENSE THIRD-PARTY-LICENSES.md libzip.txt XADMaster.txt UniversalDetector.txt Sparkle.txt 7-Zip.txt; do
  [[ -s "$APP/Contents/Resources/Licenses/$license" ]] || fail "应用包中缺少许可文件 $license"
done
for ext in FolderPreview ArchivePreview; do
  [[ -d "$APP/Contents/PlugIns/$ext.appex" ]] || fail "缺少扩展 $ext"
done
echo "交付检查通过：$(du -sh "$APP" | cut -f1)  $APP"
[[ "${SKIP_APPCAST:-0}" == 1 ]] && exit 0

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/PeekBox-$VERSION.zip"
# 与压缩包同名的 .md 由 generate_appcast 当作这一版的更新说明；内嵌进 appcast，不必另外上传
cp "$NOTES" "$OUT/PeekBox-$VERSION.md"
# generate_appcast 用钥匙串中 PeekBox 账户的私钥签名；目录里只有这个版本，不生成差量包
"$SPARKLE_BIN/generate_appcast" --account PeekBox --download-url-prefix "$URL_PREFIX" --maximum-deltas 0 \
  --embed-release-notes "$OUT"
rm "$OUT/PeekBox-$VERSION.md"
grep -q '<description' "$OUT/appcast.xml" || fail "appcast 中没有更新说明"
# 发布的二进制已去除符号，崩溃日志靠这些 dSYM 还原函数名与行号：只留本机，不上传。
# 在 generate_appcast 之后才放进输出目录，否则它会把这个压缩包也当作更新包去扫描
( cd "$DERIVED/Build/Products/Release" && zip -qry "$OUT/PeekBox-$VERSION-dSYMs.zip" *.dSYM(/) )

echo "已生成（$VERSION / $BUILD）："
echo "  $OUT/PeekBox-$VERSION.zip"
echo "  $OUT/appcast.xml"
echo "  $OUT/PeekBox-$VERSION-dSYMs.zip（只留本机，不上传）"
echo "下载地址：${URL_PREFIX}PeekBox-$VERSION.zip"
