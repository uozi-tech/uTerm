#!/usr/bin/env bash
# 在沙箱（无 PTY）环境里跑 XCTest。绕开 `xcodebuild test` 的伪终端依赖：
# 1. 用 `xcodebuild build-for-testing` 编出 test bundle
# 2. 把 host app 的 dylib 软链到 test runner 找的 rpath
# 3. 直接 `xcrun xctest <bundle>` 执行
#
# 用法：
#   bash .claude/run-tests.sh                          # 跑全部
#   bash .claude/run-tests.sh -XCTest uTermTests.AssistantModelTests
#   bash .claude/run-tests.sh -XCTest uTermTests.OpenAISSEParserTests/testDoneSentinelYieldsNil

set -eo pipefail

# 1. build
# -enableCodeCoverage NO：Xcode 17 / macOS 26.5 SDK 下，build-for-testing 默认开启
# 覆盖率插桩会让依赖框架（TreeSitter 等）引用 __llvm_profile_runtime 而链接失败。
xcodebuild build-for-testing -project uTerm.xcodeproj -scheme uTerm \
  -destination 'platform=macOS' -enableCodeCoverage NO 2>&1 | tail -3 >&2

# 2. find latest test bundle for THIS worktree's DerivedData
PROJECT_DIR="$(pwd -P)"
TEST_BUNDLE=$(find ~/Library/Developer/Xcode/DerivedData/uTerm-* \
  -name 'uTermTests.xctest' -type d 2>/dev/null | \
  while read -r b; do
    plist="$(dirname "$(dirname "$(dirname "$(dirname "$b")")")")/info.plist"
    if [[ -f "$plist" ]] && grep -q "$PROJECT_DIR" "$plist" 2>/dev/null; then
      echo "$b"
      break
    fi
  done)

if [[ -z "$TEST_BUNDLE" ]]; then
  # fallback：取最新一个
  TEST_BUNDLE=$(ls -td ~/Library/Developer/Xcode/DerivedData/uTerm-*/Build/Products/Debug/uTerm.app/Contents/PlugIns/uTermTests.xctest 2>/dev/null | head -1)
fi

if [[ -z "$TEST_BUNDLE" ]]; then
  echo "找不到 uTermTests.xctest" >&2; exit 1
fi

BUILD_DIR=$(echo "$TEST_BUNDLE" | sed 's|/uTerm.app/.*||')
APP_MACOS="$BUILD_DIR/uTerm.app/Contents/MacOS"
APP_FW="$BUILD_DIR/uTerm.app/Contents/Frameworks"

# 3. symlink dylib 到 test runner 找的 PackageFrameworks/ 位置
mkdir -p "$BUILD_DIR/PackageFrameworks"
ln -sf "$APP_MACOS/uTerm.debug.dylib" "$BUILD_DIR/PackageFrameworks/uTerm.debug.dylib"
# uTerm.debug.dylib 还依赖 Sparkle 等非 XCTest 框架——它们在 app 的 Frameworks/ 里，
# 但不在 @rpath 搜索的 PackageFrameworks/。软链进去 + DYLD_FRAMEWORK_PATH 兜底。
if [[ -d "$APP_FW" ]]; then
  for fw in "$APP_FW"/*.framework; do
    [[ -e "$fw" ]] && ln -sf "$fw" "$BUILD_DIR/PackageFrameworks/$(basename "$fw")"
  done
fi

# 4. 跑
exec env DYLD_FRAMEWORK_PATH="$BUILD_DIR:$APP_FW" xcrun xctest "$@" "$TEST_BUNDLE"
