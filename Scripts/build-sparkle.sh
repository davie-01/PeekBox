#!/bin/zsh
# 从固定提交的源码编译 Sparkle：打上 PeekBox 的补丁（Scripts/patches/sparkle-*.patch），
# 生成主应用嵌入的 Sparkle.xcframework，以及发布用的 generate_appcast / sign_update / generate_keys。
# 产物不提交仓库，克隆后执行一次本脚本即可（install.sh、release.sh 缺失时会自动调用）。
#
# 为什么不用 Swift Package 提供的预编译包：安装更新时 Sparkle 会把新应用包的修改时间改成当前时间，
# 随后立即重开并登记应用。LaunchServices 认为在修改后约 5 分钟内做的登记可能不完整，此后每次经系统启动
# 都会重新登记一次，直到某次启动晚于修改 5 分钟；每次重新登记都会结束 PeekBox 正在运行的预览扩展。
# 补丁去掉这一步，新包保留打包时的修改时间（见 release.sh），与手动解压安装的状态一致。
set -euo pipefail

# 2.10.1 标签对应的提交；升级时同时核对补丁能否应用、appcast 与 EdDSA 签名是否兼容
SPARKLE_VERSION=2.10.1
SPARKLE_COMMIT=ab7d71291238df6e0492143b120c9b696a35f603

ROOT=${0:A:h:h}
WORK="$ROOT/build/vendor/sparkle"
SRC="$WORK/Sparkle"
DERIVED="$WORK/derived"
OUT="$ROOT/Packages/PeekCore/Vendor/Sparkle.xcframework"
BIN="$WORK/bin"

mkdir -p "$WORK"
if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$SPARKLE_COMMIT" ]]; then
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 https://github.com/sparkle-project/Sparkle.git "$SPARKLE_COMMIT"
  git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
# 每次从原始源码重新打补丁
git -C "$SRC" checkout -q -- .
git -C "$SRC" clean -qfdx
for patch in "$ROOT"/Scripts/patches/sparkle-*.patch(N); do
  git -C "$SRC" apply "$patch"
done

# 与官方 XCFramework 相同的构建方式（Configurations/make-xcframework.sh）：archive Sparkle scheme。
# 内部的 Autoupdate、Updater.app 与两个 XPC 服务沿用 Sparkle 工程的 ad-hoc 签名与 hardened runtime，
# 嵌入主应用时外层框架由 Xcode 用 PeekBox 的证书重签，和此前使用的官方预编译包一致
rm -rf "$DERIVED" "$WORK/Sparkle.xcarchive"
xcodebuild archive -project "$SRC/Sparkle.xcodeproj" -scheme Sparkle -configuration Release \
  -archivePath "$WORK/Sparkle.xcarchive" -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO -quiet
FRAMEWORK="$WORK/Sparkle.xcarchive/Products/Library/Frameworks/Sparkle.framework"

# 确认补丁已编入：安装器中不再有修改时间失败的日志文案
if strings -a "$FRAMEWORK/Versions/B/Autoupdate" | grep -q "Failed to update modification and access time"; then
  echo "错误：Autoupdate 中仍在修改新应用包的修改时间（补丁未生效）" >&2
  exit 1
fi
codesign --verify --deep --strict "$FRAMEWORK"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$FRAMEWORK/Resources/Info.plist")
[[ "$BUILT_VERSION" == "$SPARKLE_VERSION" ]] || { echo "错误：编译出的 Sparkle 版本为 $BUILT_VERSION" >&2; exit 1; }

rm -rf "$OUT"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUT" >/dev/null

# 发布工具：release.sh 用 generate_appcast 生成并签名 appcast；sign_update、generate_keys 用于维护密钥
rm -rf "$BIN"
mkdir -p "$BIN"
for tool in generate_appcast sign_update generate_keys; do
  xcodebuild build -project "$SRC/Sparkle.xcodeproj" -scheme "$tool" -configuration Release \
    -derivedDataPath "$DERIVED" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO -quiet
  cp "$DERIVED/Build/Products/Release/$tool" "$BIN/"
done

echo "已生成：$OUT（Sparkle $SPARKLE_VERSION @ ${SPARKLE_COMMIT:0:7}，已打补丁）与 $BIN"
