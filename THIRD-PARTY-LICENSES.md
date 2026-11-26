# PeekBox 第三方许可

PeekBox 自有代码采用 [GNU GPL 第 3 版](LICENSE)（GPL-3.0-only）。第三方组件保留各自的版权和许可。版本以构建脚本和工程配置中固定的版本为准。随附的许可原文与版权声明位于 [licenses/](licenses/)。

## 随应用分发的依赖

| 组件 | 版本或提交 | 用途及集成方式 | 许可 | 来源与声明 |
| --- | --- | --- | --- | --- |
| libzip | 1.11.4 | ZIP 浏览、提取和写入。通过 `CLibzip` 静态链接。 | BSD-3-Clause | [上游源码](https://github.com/nih-at/libzip/tree/v1.11.4) · [原文](licenses/libzip.txt) |
| XADMaster | `7cb9ee0abbb163f261e4cb74501e15067032319c` | 7z、RAR、TAR 等归档的浏览和提取。以动态框架分发。 | 主体为 GNU LGPL v2.1，主要源码头声明 v2.1 或更高版本。内嵌组件按各自声明。 | [固定源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c) · [原文](licenses/XADMaster.txt) |
| 7-Zip | 26.06（`d3296e3`） | 磁盘镜像与文件系统（DMG、ISO、UDF、HFS+、APFS、FAT、NTFS、ext 等）的浏览和提取。只编译读取相关的格式与解码器，以动态框架 `CSevenZip.framework` 分发；框架中还包含 PeekBox 自有的桥接代码。 | 所编译的代码为 GNU LGPL v2.1 或更高版本，其中 LZFSE、Zstandard 解码为 BSD-3-Clause，XXH64 为 BSD-2-Clause。 | [固定源码](https://github.com/ip7z/7zip/tree/d3296e39e1f1f92c7b41c0c3848e65640428d42d) · [原文与说明](licenses/7-Zip.txt) |
| UniversalDetector | `4eb832d999628edcd3d134e46bd35357c8c99a85` | 字符编码检测。以动态框架分发。 | 主体为 GNU LGPL v2.1，主要源码头声明 v2.1 或更高版本。部分 Mozilla 文件提供多许可证选项。 | [固定源码](https://github.com/MacPaw/universal-detector/tree/4eb832d999628edcd3d134e46bd35357c8c99a85) · [原文](licenses/UniversalDetector.txt) |
| Sparkle | 2.10.1 | 检查和安装更新。以动态框架及其辅助程序分发。 | 主体为 MIT。附带组件见下表。 | [版本源码](https://github.com/sparkle-project/Sparkle/tree/2.10.1) · [完整声明](licenses/Sparkle.txt) |

## 依赖内嵌代码

### XADMaster

| 组件 | 许可 | 来源与声明 |
| --- | --- | --- |
| libxad（Dirk Stöcker） | LGPL-2.1-or-later，按各文件头 | [固定源码及许可](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/libxad) |
| LZMA SDK 解码与分支转换代码（Igor Pavlov） | 所用源码文件声明为公有领域 | [固定源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/lzma) · [LZMA SDK](https://www.7-zip.org/sdk.html) |
| WavPack 解码器（David Bryant / Conifer Software） | 代码头声明 BSD Software License，上游为 BSD-3-Clause | [固定源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/wavpack) · [WavPack 上游许可](https://github.com/dbry/WavPack/blob/master/license.txt) |
| AES（Brian Gladman） | 源码头中的宽松许可，要求保留版权、条件和免责条款 | [固定源码](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/Crypto/aes.h) · [源码声明](licenses/XADMaster-source-notices.txt) |
| SHA、HMAC（Aaron D. Gifford） | BSD-3-Clause，具体版权年份见文件头 | [固定源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/Crypto) · [源码声明](licenses/XADMaster-source-notices.txt) |
| MD5（Alexander Peslyak / Solar Designer） | 公有领域声明，附宽松备用条款 | [固定源码](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/Crypto/md5.c) · [源码声明](licenses/XADMaster-source-notices.txt) |
| PMarc `-pm1-` 解码（Simon Howard） | ISC 型许可，须保留版权和许可声明 | [固定源码](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/XADPMArc1Handle.m) · [源码声明](licenses/XADMaster-source-notices.txt) |
| PPMd 和 WinZip JPEG 读取代码 | 所用 XADMaster 实现的文件头声明 LGPL-2.1-or-later | [PPMd 源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/PPMd) · [WinZip JPEG 读取源码](https://github.com/MacPaw/XADMaster/tree/7cb9ee0abbb163f261e4cb74501e15067032319c/WinZipJPEG) |

RAR 读取由固定版本的 XADMaster 提供。核对过的 RAR 解码源码头声明 LGPL-2.1-or-later。PeekBox 的产品构建未引入 RARLAB UnRAR、7-Zip 的 RAR 解码代码或 7-Zip 命令行程序。 [RAR 3 读取源码](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/XADRAR30Handle.m) · [RAR 5 读取源码](https://github.com/MacPaw/XADMaster/blob/7cb9ee0abbb163f261e4cb74501e15067032319c/XADRAR50Handle.m)

### 7-Zip

PeekBox 只编译 [`Scripts/build-7zip.sh`](Scripts/build-7zip.sh) 列出的源文件，不包含受 unRAR 许可限制的 `CPP/7zip/Compress/Rar*`，脚本中有检查。对 UDF 读取的修改以补丁 [`udf-symlink.patch`](Packages/PeekCore/SevenZipBridge/patches/udf-symlink.patch) 公开，被修改的文件头注明了修改内容和日期。桥接代码 [`Packages/PeekCore/SevenZipBridge`](Packages/PeekCore/SevenZipBridge) 属于 PeekBox 自有代码，采用 GPL-3.0-only。

| 组件 | 许可 | 来源与声明 |
| --- | --- | --- |
| LZFSE 解码（Apple Inc.、Igor Pavlov） | BSD-3-Clause | [固定源码](https://github.com/ip7z/7zip/blob/d3296e39e1f1f92c7b41c0c3848e65640428d42d/CPP/7zip/Compress/LzfseDecoder.cpp) · [原文](licenses/7-Zip.txt) |
| Zstandard 解码（Facebook, Inc.、Igor Pavlov） | BSD-3-Clause | [固定源码](https://github.com/ip7z/7zip/blob/d3296e39e1f1f92c7b41c0c3848e65640428d42d/C/ZstdDec.c) · [原文](licenses/7-Zip.txt) |
| XXH64（Yann Collet、Igor Pavlov） | BSD-2-Clause | [固定源码](https://github.com/ip7z/7zip/blob/d3296e39e1f1f92c7b41c0c3848e65640428d42d/C/Xxh64.c) · [原文](licenses/7-Zip.txt) |

### UniversalDetector

UniversalDetector 内含 Mozilla Universal Charset Detector 的代码。原始文件头提供 MPL 1.1、GPL v2 或更高版本、LGPL v2.1 或更高版本的选择。各文件的版权和授权以源码头为准。 [固定源码及声明](https://github.com/MacPaw/universal-detector/tree/4eb832d999628edcd3d134e46bd35357c8c99a85/universalchardet)

### Sparkle

| 组件 | 许可 | 来源与声明 |
| --- | --- | --- |
| bsdiff / bspatch 4.3（Colin Percival） | BSD-2-Clause | [上游](https://www.daemonology.net/bsdiff/) · [Sparkle 随附声明](licenses/Sparkle.txt) |
| sais-lite（Yuta Mori） | MIT | [上游](https://sites.google.com/site/yuta256/sais) · [Sparkle 随附声明](licenses/Sparkle.txt) |
| Portable C Ed25519（Orson Peters） | zlib 风格的宽松许可 | [上游](https://github.com/orlp/ed25519) · [Sparkle 随附声明](licenses/Sparkle.txt) |
| `SUSignatureVerifier.m` 中的 Mark Hamlin 代码 | BSD-2-Clause | [Sparkle 随附声明](licenses/Sparkle.txt) |

## 开发工具和测试材料

| 项目 | 在 PeekBox 中的用途 | 许可 | 来源与声明 |
| --- | --- | --- | --- |
| XcodeGen | 开发机上生成 Xcode 工程 | MIT | [上游](https://github.com/yonaskolb/XcodeGen) · [原文](licenses/XcodeGen.txt) |
| CMake | 开发机上构建 libzip | BSD-3-Clause | [上游](https://cmake.org/licensing/) · [原文](licenses/CMake.txt) |
| 7-Zip 命令行程序 `7zz` | 可选的引擎对比、样本生成和 ZIP 交叉验证工具，不随应用分发 | 主体为 LGPL-2.1-or-later，部分代码另有 unRAR 限制及 BSD 2/3 条款 | [上游](https://github.com/ip7z/7zip) · [许可条款](licenses/7-Zip.txt) |
| libarchive 测试语料 | 仓库内的 RAR4/RAR5 加密、压缩、分卷测试样本。测试也会调用系统的 `bsdtar`。 | 上游 `COPYING` 说明项目主要采用 BSD-2-Clause，文件如有单独声明以该声明为准。归档内负载须按原件核对。 | [上游测试目录](https://github.com/libarchive/libarchive/tree/master/libarchive/test) · [COPYING](licenses/libarchive.txt) |

构建还使用 Apple 的 Xcode、macOS SDK 和系统工具。AppKit、SwiftUI、Quick Look、NSXPC、ServiceManagement、CommonCrypto，以及链接的系统 zlib 和 bzip2 由 Apple 平台提供。开发与测试阶段使用的命令行程序由各自工具链提供。

## 发行包中的声明与对应源码

分发 ZIP 时，应在发行物中随附适用的许可证、版权声明和免责声明，并给出与该二进制对应的源码获取方式。XADMaster、UniversalDetector 与 CSevenZip 以独立的动态框架位于 `PeekBox.app/Contents/Frameworks`，对应源码由构建脚本按固定版本获取；替换或重新链接方式需要结合最终打包与签名配置核对。 [GPL v3 第 6 节](https://www.gnu.org/licenses/gpl-3.0.html#section6) · [LGPL v2.1 第 6 节](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html#SEC3)

发行时应以实际捆绑版本的声明为准。WavPack 表项链接到其上游公开许可和 PeekBox 所用的固定源码，RAR 测试语料的来源与许可范围见测试材料表。
