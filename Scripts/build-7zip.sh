#!/bin/zsh
# 拉取固定版本的 7-Zip 源码，只编译磁盘镜像与文件系统相关的只读 handler，连同 PeekBox 的桥接层
# （Packages/PeekCore/SevenZipBridge）编译为 arm64 动态框架，打包为 PeekCore 使用的 CSevenZip.xcframework。
# 不编译 CPP/7zip/Compress/Rar*：这部分受 unRAR 许可限制，RAR 继续由 XADMaster 读取。
# 产物不提交仓库，克隆后执行一次本脚本即可；修改桥接层后重新执行。
set -euo pipefail

VERSION=26.06
COMMIT=d3296e39e1f1f92c7b41c0c3848e65640428d42d

ROOT=${0:A:h:h}
WORK="$ROOT/build/vendor/7zip"
SRC="$WORK/src"
OBJ="$WORK/obj"
BRIDGE="$ROOT/Packages/PeekCore/SevenZipBridge"
OUT="$ROOT/Packages/PeekCore/Vendor/CSevenZip.xcframework"

if [[ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]]; then
  rm -rf "$SRC"
  git init -q "$SRC"
  git -C "$SRC" fetch -q --depth 1 https://github.com/ip7z/7zip.git "$COMMIT"
  git -C "$SRC" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi

# PeekBox 对 7-Zip 的修补（SevenZipBridge/patches）：每次从固定版本的原始源码重新打补丁
git -C "$SRC" checkout -q -- .
for patch in "$BRIDGE"/patches/*.patch(N); do
  git -C "$SRC" apply "$patch"
done

SOURCES=(
  # 基础 C 代码：CRC、哈希、解码器
  C/7zCrc.c C/7zCrcOpt.c C/Alloc.c C/CpuArch.c C/Bra.c C/Bra86.c C/BraIA64.c C/Delta.c
  C/LzmaDec.c C/Lzma2Dec.c C/Sha1.c C/Sha1Opt.c C/Sha256.c C/Sha256Opt.c
  C/7zStream.c C/Lzma2DecMt.c C/Xz.c C/XzCrc64.c C/XzCrc64Opt.c C/XzDec.c C/XzIn.c C/ZstdDec.c C/Xxh64.c C/Sort.c C/SwapBytes.c
  # 公共 C++ 代码
  CPP/Common/CRC.cpp CPP/Common/IntToString.cpp CPP/Common/MyString.cpp CPP/Common/MyVector.cpp
  CPP/Common/MyXml.cpp CPP/Common/MyMap.cpp CPP/Common/NewHandler.cpp CPP/Common/StringConvert.cpp
  CPP/Common/StringToInt.cpp CPP/Common/UTFConvert.cpp CPP/Common/MyWindows.cpp CPP/Common/DynLimBuf.cpp
  CPP/Common/Sha1Prepare.cpp CPP/Common/Sha256Prepare.cpp CPP/Common/XzCrc64Init.cpp
  CPP/Windows/FileIO.cpp CPP/Windows/FileName.cpp CPP/Windows/PropVariant.cpp
  CPP/Windows/PropVariantConv.cpp CPP/Windows/PropVariantUtils.cpp CPP/Windows/TimeUtils.cpp
  CPP/Windows/System.cpp CPP/Windows/FileDir.cpp CPP/Windows/FileFind.cpp
  CPP/7zip/Common/CreateCoder.cpp CPP/7zip/Common/CWrappers.cpp CPP/7zip/Common/FileStreams.cpp
  CPP/7zip/Common/FilterCoder.cpp CPP/7zip/Common/InBuffer.cpp CPP/7zip/Common/LimitedStreams.cpp
  CPP/7zip/Common/MethodId.cpp CPP/7zip/Common/MethodProps.cpp CPP/7zip/Common/OffsetStream.cpp
  CPP/7zip/Common/OutBuffer.cpp CPP/7zip/Common/ProgressUtils.cpp CPP/7zip/Common/PropId.cpp
  CPP/7zip/Common/StreamObjects.cpp CPP/7zip/Common/StreamUtils.cpp
  # 格式注册与公共部分
  CPP/7zip/Archive/ArchiveExports.cpp CPP/7zip/Archive/HandlerCont.cpp
  CPP/7zip/Archive/Common/ItemNameUtils.cpp CPP/7zip/Archive/Common/OutStreamWithCRC.cpp
  CPP/7zip/Archive/Common/InStreamWithCRC.cpp CPP/7zip/Archive/Common/MultiStream.cpp
  CPP/7zip/Archive/Common/FindSignature.cpp
  # DMG 的 plist 用 Base64 编码、ext4 用 LZH 的 CRC16：这两个函数随各自 handler 文件提供（格式本身不会被尝试）
  CPP/7zip/Archive/Base64Handler.cpp CPP/7zip/Archive/LzhHandler.cpp
  # 磁盘镜像、分区表与文件系统
  CPP/7zip/Archive/DmgHandler.cpp CPP/7zip/Archive/HfsHandler.cpp CPP/7zip/Archive/ApfsHandler.cpp
  CPP/7zip/Archive/FatHandler.cpp CPP/7zip/Archive/NtfsHandler.cpp CPP/7zip/Archive/ExtHandler.cpp
  CPP/7zip/Archive/GptHandler.cpp CPP/7zip/Archive/MbrHandler.cpp CPP/7zip/Archive/ApmHandler.cpp
  CPP/7zip/Archive/VhdHandler.cpp CPP/7zip/Archive/VhdxHandler.cpp CPP/7zip/Archive/VmdkHandler.cpp
  CPP/7zip/Archive/QcowHandler.cpp CPP/7zip/Archive/VdiHandler.cpp CPP/7zip/Archive/SparseHandler.cpp
  CPP/7zip/Archive/SquashfsHandler.cpp CPP/7zip/Archive/CramfsHandler.cpp
  CPP/7zip/Archive/Iso/IsoHandler.cpp CPP/7zip/Archive/Iso/IsoHeader.cpp CPP/7zip/Archive/Iso/IsoIn.cpp
  CPP/7zip/Archive/Iso/IsoRegister.cpp
  CPP/7zip/Archive/Udf/UdfHandler.cpp CPP/7zip/Archive/Udf/UdfIn.cpp
  # 上述格式用到的解码器
  CPP/7zip/Compress/CopyCoder.cpp CPP/7zip/Compress/BZip2Crc.cpp CPP/7zip/Compress/BZip2Decoder.cpp
  CPP/7zip/Compress/DeflateDecoder.cpp CPP/7zip/Compress/ZlibDecoder.cpp CPP/7zip/Compress/LzfseDecoder.cpp
  CPP/7zip/Compress/LzmaDecoder.cpp CPP/7zip/Compress/Lzma2Decoder.cpp CPP/7zip/Compress/XzDecoder.cpp
  CPP/7zip/Compress/ZstdDecoder.cpp CPP/7zip/Compress/LzOutWindow.cpp CPP/7zip/Compress/BitlDecoder.cpp
  CPP/7zip/Compress/XpressDecoder.cpp CPP/7zip/Compress/LzxDecoder.cpp CPP/7zip/Compress/LzhDecoder.cpp
)

if (( ${SOURCES[(I)*Compress/Rar*]} )); then
  echo "错误：源码清单包含受 unRAR 许可限制的 Rar 解码器" >&2
  exit 1
fi

SDK=$(xcrun --sdk macosx --show-sdk-path)
COMMON_FLAGS=(
  -arch arm64 -mmacosx-version-min=26.0 -isysroot "$SDK" -O2 -fPIC -w
  -DZ7_ST -DZ7_NO_LARGE_PAGES -D_FILE_OFFSET_BITS=64 -DNDEBUG
  -I"$SRC/CPP" -I"$SRC/C"
)

rm -rf "$OBJ"
mkdir -p "$OBJ"

compile() {
  local file=$1 output=$2
  case $file in
    *.c) xcrun clang -std=c11 "${COMMON_FLAGS[@]}" -c "$file" -o "$output" ;;
    *) xcrun clang++ -std=c++17 "${COMMON_FLAGS[@]}" -c "$file" -o "$output" ;;
  esac
}

# 并行编译；7-Zip 源码各自引用同目录下的 StdAfx.h，按原路径编译即可
JOBS=$(sysctl -n hw.ncpu)
typeset -a PIDS
for file in "${SOURCES[@]}"; do
  compile "$SRC/$file" "$OBJ/${file//\//_}.o" &
  PIDS+=($!)
  if (( ${#PIDS} >= JOBS )); then wait "${PIDS[1]}"; PIDS=("${PIDS[@]:1}"); fi
done
compile "$BRIDGE/PeekSevenZip.cpp" "$OBJ/PeekSevenZip.o" &
PIDS+=($!)
for pid in "${PIDS[@]}"; do wait "$pid"; done

# 动态框架：两个预览扩展与后台服务都经 rpath 加载主应用 Contents/Frameworks 中的同一份（与 XADMaster 相同），
# 不在每个可执行文件里各链一份。全部目标文件直接链入，各 handler 的静态注册代码随之保留；
# 只导出桥接接口，其余死代码剥离
FRAMEWORK="$WORK/CSevenZip.framework"
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK/Versions/A/Headers" "$FRAMEWORK/Versions/A/Modules" "$FRAMEWORK/Versions/A/Resources"
xcrun clang++ -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -isysroot "$SDK" "$OBJ"/*.o \
  -install_name @rpath/CSevenZip.framework/Versions/A/CSevenZip \
  -compatibility_version 1 -current_version "$VERSION" -dead_strip \
  -exported_symbols_list <(print -l _psz_open _psz_close _psz_item_count _psz_item _psz_format \
    _psz_volume_name _psz_extract _psz_version _psz_free) \
  -o "$FRAMEWORK/Versions/A/CSevenZip"
cp "$BRIDGE/PeekSevenZip.h" "$FRAMEWORK/Versions/A/Headers/"
cat > "$FRAMEWORK/Versions/A/Modules/module.modulemap" <<'EOF'
framework module CSevenZip {
    umbrella header "PeekSevenZip.h"
    export *
}
EOF
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>CSevenZip</string>
    <key>CFBundleIdentifier</key><string>com.mars.PeekBox.CSevenZip</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>CSevenZip</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict>
</plist>
EOF
ln -s A "$FRAMEWORK/Versions/Current"
for item in CSevenZip Headers Modules Resources; do
  ln -s "Versions/Current/$item" "$FRAMEWORK/$item"
done

# 只应导出桥接接口；7-Zip 的符号在上面链接时已全部解析，缺源文件会直接报错
EXPORTED=$(xcrun nm -gU "$FRAMEWORK/CSevenZip" | awk '{print $3}' | sort | tr '\n' ' ')
[[ "$EXPORTED" == "_psz_close _psz_extract _psz_format _psz_free _psz_item _psz_item_count _psz_open _psz_version _psz_volume_name " ]] \
  || { echo "错误：导出符号不符：$EXPORTED" >&2; exit 1; }

rm -rf "$OUT"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUT" >/dev/null

echo "已生成：$OUT（7-Zip $VERSION，$(du -h "$FRAMEWORK/Versions/A/CSevenZip" | cut -f1)）"
