#!/bin/zsh
# 拉取固定提交的 XADMaster 与 UniversalDetector，编译 arm64 动态框架，打包为 PeekCore 使用的 XCFramework。
# 产物不提交仓库，克隆后执行一次本脚本即可。
set -euo pipefail

# master 上 2026-09-21 的提交（含 2026-08 的 StuffIt X 溢出修复），比 2023 年的 v1.10.8 标签更新
XAD_COMMIT=7cb9ee0abbb163f261e4cb74501e15067032319c
# 仓库已归档，使用最后一个提交
UD_COMMIT=4eb832d999628edcd3d134e46bd35357c8c99a85

ROOT=${0:A:h:h}
WORK="$ROOT/build/vendor/xadmaster"
VENDOR="$ROOT/Packages/PeekCore/Vendor"

fetch() {
  local url=$1 commit=$2 dir=$3
  if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
    return
  fi
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$url" "$commit"
  git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

mkdir -p "$WORK"
# XADMaster 工程按相对路径 ../UniversalDetector 引用依赖
fetch https://github.com/MacPaw/XADMaster.git "$XAD_COMMIT" "$WORK/XADMaster"
fetch https://github.com/MacPaw/universal-detector.git "$UD_COMMIT" "$WORK/UniversalDetector"

rm -rf "$WORK/out"
xcodebuild -project "$WORK/XADMaster/XADMaster.xcodeproj" -target XADMaster -configuration Release \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=26.0 \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$WORK/out" build -quiet 2>&1 \
  | grep -v -E "deprecated|^\s*[0-9]+ \||^\s*\||note:|^$" || true

PRODUCTS="$WORK/out/Release"
for name in XADMaster UniversalDetector; do
  if [[ ! -d "$PRODUCTS/$name.framework" ]]; then
    echo "错误：未生成 $name.framework" >&2
    exit 1
  fi
  rm -rf "$VENDOR/$name.xcframework"
  xcodebuild -create-xcframework -framework "$PRODUCTS/$name.framework" \
    -output "$VENDOR/$name.xcframework" >/dev/null
done

echo "已生成：XADMaster @ ${XAD_COMMIT:0:7}，UniversalDetector @ ${UD_COMMIT:0:7}"
