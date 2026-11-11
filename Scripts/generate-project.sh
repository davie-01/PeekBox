#!/bin/zsh
# 生成 Xcode 工程（XcodeGen），并修正 XcodeGen 不认识的文件类型。
# 所有构建（install.sh、sync-strings.sh、release.sh）与在 Xcode 中打开工程前都应运行它，不要直接运行 xcodegen。
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
xcodegen generate --quiet
# XcodeGen 把 Icon Composer 图标识别为旧的 wrapper.icon，Xcode 不会编译它（应用显示空白图标）：
# 改为 Xcode 26 的文件类型
sed -i '' 's/lastKnownFileType = wrapper.icon; path = AppIcon.icon;/lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;/' \
  PeekBox.xcodeproj/project.pbxproj
grep -q "folder.iconcomposer.icon" PeekBox.xcodeproj/project.pbxproj || { echo "错误：AppIcon.icon 文件类型未修正" >&2; exit 1; }
