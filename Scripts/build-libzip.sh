#!/bin/zsh
# 下载固定版本 libzip 源码，编译 arm64 静态库，打包为 PeekCore 使用的 XCFramework。
# 依赖：cmake（brew install cmake）。产物不提交仓库，克隆后执行一次本脚本即可。
set -euo pipefail

VERSION=1.11.4
SHA256=82e9f2f2421f9d7c2466bbc3173cd09595a88ea37db0d559a9d0a2dc60dc722e

ROOT=${0:A:h:h}
WORK="$ROOT/build/vendor/libzip"
SRC="$WORK/libzip-$VERSION"
OUT="$ROOT/Packages/PeekCore/Vendor/libzip.xcframework"

mkdir -p "$WORK"
TARBALL="$WORK/libzip-$VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  curl -fsSL -o "$TARBALL" "https://github.com/nih-at/libzip/releases/download/v$VERSION/libzip-$VERSION.tar.gz"
fi
ACTUAL=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "错误：libzip 源码包校验值不符：$ACTUAL" >&2
  exit 1
fi

rm -rf "$SRC" "$WORK/build" "$WORK/install"
tar -xzf "$TARBALL" -C "$WORK"

# 只启用系统自带的 zlib / bzip2 / CommonCrypto，不链接 Homebrew 中的库
cmake -S "$SRC" -B "$WORK/build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
  -DCMAKE_INSTALL_PREFIX="$WORK/install" \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_COMMONCRYPTO=ON -DENABLE_GNUTLS=OFF -DENABLE_MBEDTLS=OFF \
  -DENABLE_OPENSSL=OFF -DENABLE_WINDOWS_CRYPTO=OFF \
  -DENABLE_BZIP2=ON -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
  -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF >/dev/null
cmake --build "$WORK/build" --parallel >/dev/null
cmake --install "$WORK/build" >/dev/null

HEADERS="$WORK/headers"
rm -rf "$HEADERS"
mkdir -p "$HEADERS"
cp "$WORK/install/include/zip.h" "$WORK/install/include/zipconf.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module CLibzip {
    header "zip.h"
    link "z"
    link "bz2"
    export *
}
EOF

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/install/lib/libzip.a" -headers "$HEADERS" \
  -output "$OUT" >/dev/null

echo "已生成：$OUT（libzip $VERSION）"
