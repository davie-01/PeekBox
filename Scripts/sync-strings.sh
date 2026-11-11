#!/bin/zsh
# 用编译器提取界面文案（SWIFT_EMIT_LOC_STRINGS），同步进各 String Catalog，再套用 Scripts/translations-en.json 的英文翻译。
# 新增或修改界面文案后运行一次。
set -euo pipefail
ROOT=${0:A:h:h}
BUILD_DIR="$ROOT/build/DerivedData"
INTER="$BUILD_DIR/Build/Intermediates.noindex"
cd "$ROOT"

./Scripts/generate-project.sh
xcodebuild -project PeekBox.xcodeproj -scheme PeekBox -configuration Debug \
  -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS,arch=arm64' \
  build -quiet SWIFT_EMIT_LOC_STRINGS=YES

sync() {
  local catalog=$1; shift
  local files=()
  for dir in "$@"; do files+=("${(@f)$(find "$dir" -name '*.stringsdata')}"); done
  xcrun xcstringstool sync "$catalog" --stringsdata "${files[@]}"
  echo "synced $catalog (${#files} stringsdata)"
}

# 后台服务与主应用共用主应用的文案表（后台服务位于主应用 Contents/MacOS，Bundle.main 即主应用）
sync App/Localizable.xcstrings "$INTER/PeekBox.build/Debug/PeekBox.build" "$INTER/PeekBox.build/Debug/PeekBoxBroker.build"
sync Packages/PeekCore/Sources/PeekCore/Resources/Localizable.xcstrings "$INTER/PeekCore.build"
sync Packages/PeekUI/Sources/PeekUI/Resources/Localizable.xcstrings "$INTER/PeekUI.build"

python3 -I Scripts/apply-translations.py Scripts/translations-en.json \
  App/Localizable.xcstrings \
  Packages/PeekCore/Sources/PeekCore/Resources/Localizable.xcstrings \
  Packages/PeekUI/Sources/PeekUI/Resources/Localizable.xcstrings
