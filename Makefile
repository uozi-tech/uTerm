SHELL := /bin/sh

APP_NAME := uTerm
PROJECT := uTerm.xcodeproj
SCHEME := uTerm
CONFIGURATION ?= Release
TEST_CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS

# iOS/iPadOS 模拟器目标（uTermMobile scheme + uTermMobileTests bundle）。
# 换机器：make test-mobile MOBILE_DESTINATION='platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
# 这台机器上没有 iOS 模拟器运行时的话先跑一次 `xcodebuild -downloadPlatform iOS`（8.5GB）。
MOBILE_SCHEME ?= uTermMobile
MOBILE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro

BUILD_DIR := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app
DMG_PATH := $(BUILD_DIR)/$(APP_NAME).dmg
DMG_RW := $(BUILD_DIR)/rw.dmg
DMG_BG := $(BUILD_DIR)/dmg-background@2x.png
DMG_MOUNT := /Volumes/$(APP_NAME)
NOTARY_RESULT := $(BUILD_DIR)/notary-result.json

TEAM_ID ?= ABCDE12345
CODE_SIGN_IDENTITY ?= Developer ID Application
NOTARY_PROFILE ?= AC_PASSWORD

DEVELOPMENT_TEAM_ARG := $(if $(TEAM_ID),DEVELOPMENT_TEAM=$(TEAM_ID),)
CODE_SIGN_IDENTITY_ARG := $(if $(CODE_SIGN_IDENTITY),CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)",)
CODE_SIGN_STYLE := $(if $(CODE_SIGN_IDENTITY),Manual,Automatic)
TIMESTAMP_ARG := $(if $(CODE_SIGN_IDENTITY),OTHER_CODE_SIGN_FLAGS=--timestamp,)
ENTITLEMENTS_ARG := $(if $(CODE_SIGN_IDENTITY),CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO,)
SIGNING_ARGS := CODE_SIGN_STYLE=$(CODE_SIGN_STYLE) ENABLE_HARDENED_RUNTIME=YES $(DEVELOPMENT_TEAM_ARG) $(CODE_SIGN_IDENTITY_ARG) $(TIMESTAMP_ARG) $(ENTITLEMENTS_ARG)

# Developer ID distribution uses an archive + export flow (not a plain `build`). The app
# target carries iCloud / CloudKit entitlements, which require a Developer ID provisioning
# profile that includes the iCloud.com.uozi.uTerm container. `xcodebuild -exportArchive`
# with method=developer-id (automatic signing + -allowProvisioningUpdates) mints/refreshes
# that profile via your Apple Developer account, applies it to the app target only (SPM
# framework targets do not take profiles), and produces a Developer-ID-signed, hardened,
# timestamped, notarizable app with the profile embedded. Requires Xcode signed in to an
# Apple ID with access to TEAM_ID and a "Developer ID Application" certificate.
ARCHIVE_PATH := $(BUILD_DIR)/$(APP_NAME).xcarchive
EXPORT_DIR := $(BUILD_DIR)/export
EXPORT_APP := $(EXPORT_DIR)/$(APP_NAME).app
EXPORT_OPTIONS := $(BUILD_DIR)/export-options.plist

# iOS / TestFlight 分发。与 macOS 同构：archive（automatic 开发签名）+ export（重签成
# 分发签名）。差别是 method=app-store-connect、产物是 .ipa、终点是 App Store Connect
# 而不是 OSS + Sparkle —— iOS 没有 Sparkle，更新走 TestFlight / App Store。
# 导出选项是**受跟踪文件**（Config/ExportOptions-ios*.plist），不像 macOS 那样在 build/ 里现生成，
# 因为里面写着法务/能力相关的约定（manageAppVersionAndBuildNumber=false 等），值得进版本库。
MOBILE_APP_NAME := uTermMobile
MOBILE_BUILD_DIR := $(BUILD_DIR)/mobile
MOBILE_ARCHIVE_PATH := $(MOBILE_BUILD_DIR)/$(MOBILE_APP_NAME).xcarchive
MOBILE_EXPORT_DIR := $(MOBILE_BUILD_DIR)/export
MOBILE_UPLOAD_DIR := $(MOBILE_BUILD_DIR)/upload
MOBILE_VERIFY_DIR := $(MOBILE_BUILD_DIR)/verify
MOBILE_IPA := $(MOBILE_EXPORT_DIR)/$(MOBILE_APP_NAME).ipa
MOBILE_ARCHIVE_APP := $(MOBILE_ARCHIVE_PATH)/Products/Applications/$(MOBILE_APP_NAME).app
MOBILE_EXPORT_OPTIONS := Config/ExportOptions-ios.plist
MOBILE_UPLOAD_OPTIONS := Config/ExportOptions-ios-upload.plist
# 发布 archive 钉住 Package.resolved：依赖版本可复现，且远端偶发不可达时不会整条失败。
# 想让它照常联网解析依赖就传空值：make archive-mobile MOBILE_PACKAGE_ARGS=
MOBILE_PACKAGE_ARGS ?= -onlyUsePackageVersionsFromResolvedFile
# macOS archive 同理：默认钉在 Package.resolved 上、不联网刷新依赖镜像。uAppKit ≥ 1.4.6 的清单用 git@github.com: 形式引用
# swift-nio / swift-log 等，与根工程的 https 形式同名异址，Xcode 的 SwiftPM 在「Updating from …」阶段会互锁挂死（0% CPU、无 git 子进程）。
# 想照常联网解析依赖就传空值：make release PACKAGE_ARGS=
PACKAGE_ARGS ?= -disableAutomaticPackageResolution -skipPackageUpdates

# 本次发版的分组发布日志（Markdown）。同一份文案喂三个地方：企微分组通告、
# TestFlight 的 What to Test、RELEASE_LOG.md 的「本次更新」。约定路径带版本与
# build 号，且**必须在 archive 之前写好**——`make release` 的 clean 会清空 build/，
# 但 iOS 这条链路不跑 clean，所以放 build/mobile/notes/ 是安全的。
# 显式覆盖：make notify-mobile NOTES=path/to/notes.md
# 用递归展开（=，不是 :=）：MOBILE_VERSION / BUILD_NUMBER 在文件更下面才定义。
MOBILE_NOTES_PATH = $(MOBILE_BUILD_DIR)/notes/$(MOBILE_APP_NAME)-$(MOBILE_VERSION)-$(BUILD_NUMBER).md
NOTES ?= $(wildcard $(MOBILE_NOTES_PATH))

# App Store Connect 认证片段，archive / export / upload 三处共用一份。
# 从 $(ENV_FILE) 读 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH（见 .env.example），三个
# 都配齐才拼出 xcodebuild 的 -authenticationKey* 三件套并写进 shell 变量 $$auth；否则
# $$auth 为空，回退到 Xcode 已登录的 Apple ID。
# 这三个参数不只是上传要用：-allowProvisioningUpdates 用它们代替「Xcode 登录的账号」去
# App Store Connect 自动签发 Apple Distribution 证书与 App Store profile（Xcode 13+），
# 所以 archive 与 export 也要带上 —— 本机没登录任何有权限的账号时，这是唯一的走法。
# 用法（必须和 xcodebuild 在同一个 shell 里）：
#   @set -e; $(MOBILE_ASC_AUTH); xcodebuild ... -allowProvisioningUpdates $$auth
# xcodebuild 的 IDEDistributionCreateIPAStep 会调 /usr/bin/rsync 拷 Symbols/Root，而 Apple 的
# openrsync 客户端会**按 PATH** 再起一个 `rsync` 当服务端。本机 PATH 里 Homebrew 的
# /opt/homebrew/bin/rsync（3.5.0）排在前面被选中，它不认 openrsync 把 -E 展开成的
# --extended-attributes，于是整步失败成一句没头没脑的 `error: exportArchive Copy failed`
# （真话在 /usr/bin/log 里：`rsync: on remote machine: --extended-attributes: unknown option`）。
# 把系统路径顶到 PATH 最前面，只作用于这一条 xcodebuild。
MOBILE_EXPORT_PATH_FIX = PATH="/usr/bin:/bin:/usr/sbin:/sbin:$$PATH"

MOBILE_ASC_AUTH = \
	if [ -f "$(ENV_FILE)" ]; then set -a; . ./$(ENV_FILE); set +a; fi; \
	auth=""; \
	if [ -n "$${ASC_KEY_ID:-}" ] && [ -n "$${ASC_ISSUER_ID:-}" ] && [ -n "$${ASC_KEY_PATH:-}" ]; then \
		printf '%s\n' "Authenticating with App Store Connect API key $$ASC_KEY_ID"; \
		test -f "$$ASC_KEY_PATH" || { printf '%s\n' "ERROR: ASC_KEY_PATH=$$ASC_KEY_PATH does not exist."; exit 1; }; \
		auth="-authenticationKeyPath $$ASC_KEY_PATH -authenticationKeyID $$ASC_KEY_ID -authenticationKeyIssuerID $$ASC_ISSUER_ID"; \
	else \
		printf '%s\n' "No ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH in $(ENV_FILE); using the Apple ID Xcode is signed in to."; \
	fi

INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Sparkle auto-update / OSS publishing
SPARKLE_VERSION ?= 2.9.6
SPARKLE_TARBALL := Sparkle-$(SPARKLE_VERSION).tar.xz
SPARKLE_URL := https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/$(SPARKLE_TARBALL)
SPARKLE_DIR := $(BUILD_DIR)/sparkle-tools
SPARKLE_BIN := $(SPARKLE_DIR)/bin
GENERATE_KEYS := $(SPARKLE_BIN)/generate_keys
GENERATE_APPCAST := $(SPARKLE_BIN)/generate_appcast
APPCAST_DIR := $(BUILD_DIR)/appcast
ENV_FILE := .env
VERSION_XCCONFIG := Config/Version.xcconfig
# Single source of truth: read MARKETING_VERSION from the xcconfig; allow VERSION override.
VERSION ?= $(shell scripts/bump-version.sh print)
# iOS 的版本号是**另一份**真值源（Config/VersionMobile.xcconfig，由 uTermMobile /
# uTermMobileTests 的 target 级 baseConfigurationReference 叠在 project 级之上覆盖）。
# 两个平台在各自的商店里独立递增，所有 mobile 目标一律读 MOBILE_VERSION，不要用 VERSION。
MOBILE_VERSION_XCCONFIG := Config/VersionMobile.xcconfig
MOBILE_VERSION ?= $(shell scripts/bump-version.sh --mobile print)
# Build id; matches the "Set Build Number" Run Script (git commit count).
# build 号 = git 提交数 + Config/BuildNumberOffset（与 pbxproj 里两份 Set Build Number Run Script 同一算法；
# 偏移量的来历见 CLAUDE.md「Build Versioning」，只能调大不能调小）。
BUILD_NUMBER ?= $(shell echo $$(( $$(git rev-list --count HEAD) + $$(cat Config/BuildNumberOffset 2>/dev/null || echo 0) )))
APPCAST_DMG_NAME := $(APP_NAME)-$(VERSION)-$(BUILD_NUMBER).dmg
APPCAST_RELEASE_NOTES_NAME := $(APP_NAME)-$(VERSION)-$(BUILD_NUMBER).html
LEGACY_RELEASE_NOTES_NAME := $(APP_NAME)-$(VERSION).html

.PHONY: help list print-version print-build set-version bump-patch bump-minor bump-major \
	print-version-mobile set-version-mobile bump-patch-mobile bump-minor-mobile bump-major-mobile tag-mobile \
	build archive export-app test test-mobile check-cli check-skills check-cloudkit-schema clean dmg dmg-background sign-release-app install verify \
	verify-distribution-signing notarize staple \
	archive-mobile export-mobile verify-mobile-signing upload-mobile notify-mobile \
	testflight-notes-mobile release-mobile \
	release tag notify sparkle-tools sparkle-keys appcast publish distribute dry-run

help:
	@printf '%s\n' 'uTerm packaging commands:'
	@printf '%s\n' ''
	@printf '%s\n' '  make print-version                     Print current MARKETING_VERSION'
	@printf '%s\n' '  make print-build                       Print build number (git count + Config/BuildNumberOffset)'
	@printf '%s\n' '  make set-version VERSION=x.y.z         Set the semantic version'
	@printf '%s\n' '  make bump-patch|bump-minor|bump-major  Increment the semantic version'
	@printf '%s\n' '  make build                             Build the macOS app in Release mode'
	@printf '%s\n' '  make archive                           Archive the app (automatic signing)'
	@printf '%s\n' '  make export-app                        Export a Developer ID-signed app from the archive'
	@printf '%s\n' '  make test                              Run tests with xcodebuild'
	@printf '%s\n' '  make test-mobile                       Run uTermMobileTests on an iOS Simulator'
	@printf '%s\n' '  make check-cli                         Self-test scripts/utermctl (no Xcode, no uTerm)'
	@printf '%s\n' '  make check-skills                      Run the bundled skills / utermctl tests'
	@printf '%s\n' '  make check-cloudkit-schema             Diff @Model against the deployed CloudKit schema'
	@printf '%s\n' '  make clean                             Remove build artifacts'
	@printf '%s\n' '  make dmg                               Archive, export and package build/uTerm.dmg'
	@printf '%s\n' '  make install                           Install the app to /Applications'
	@printf '%s\n' '  make verify                            Verify app signing / Gatekeeper'
	@printf '%s\n' '  make notarize                          Submit the DMG for notarization'
	@printf '%s\n' '  make staple                            Staple the notarization ticket'
	@printf '%s\n' '  make release                           Archive, export, package, verify, notarize, staple'
	@printf '%s\n' '  make sparkle-tools                     Download Sparkle CLI tools'
	@printf '%s\n' '  make sparkle-keys                      Generate the one-time Sparkle EdDSA keypair'
	@printf '%s\n' '  make appcast                           Stage DMG and generate appcast.xml'
	@printf '%s\n' '  make publish                           Upload DMG + appcast.xml to OSS'
	@printf '%s\n' '  make notify                            Send WeCom release notification'
	@printf '%s\n' '  make distribute                        release, appcast, publish, notify'
	@printf '%s\n' '  make dry-run                           Validate release commands (no network)'
	@printf '%s\n' ''
	@printf '%s\n' '  iOS / TestFlight:'
	@printf '%s\n' '  make print-version-mobile              Print uTermMobile MARKETING_VERSION'
	@printf '%s\n' '  make set-version-mobile VERSION=x.y.z  Set the uTermMobile semantic version'
	@printf '%s\n' '  make bump-{patch,minor,major}-mobile   Increment the uTermMobile semantic version'
	@printf '%s\n' '  make archive-mobile                    Archive uTermMobile for generic/platform=iOS'
	@printf '%s\n' '  make export-mobile                     Export an App Store-signed .ipa + verify signing'
	@printf '%s\n' '  make verify-mobile-signing             Check the .ipa signing authority / entitlements'
	@printf '%s\n' '  make upload-mobile                     Upload the archive to App Store Connect (TestFlight)'
	@printf '%s\n' '  make notify-mobile [NOTES=notes.md]    Send the WeCom TestFlight notification'
	@printf '%s\n' '  make testflight-notes-mobile NOTES=f   Write TestFlight "What to Test" via the ASC API'
	@printf '%s\n' '  make release-mobile [NOTES=notes.md]   archive, export, upload, notify, TestFlight notes'
	@printf '%s\n' '  make tag-mobile                        Create the mobile-v<VERSION> git tag'

list:
	xcodebuild -list -project "$(PROJECT)"

print-version:
	@scripts/bump-version.sh print

print-build:
	@echo $(BUILD_NUMBER)

set-version:
	@[ "$(origin VERSION)" = "command line" ] || { echo 'Usage: make set-version VERSION=x.y.z' >&2; exit 1; }
	@scripts/bump-version.sh set "$(VERSION)"

bump-patch:
	@scripts/bump-version.sh patch

bump-minor:
	@scripts/bump-version.sh minor

bump-major:
	@scripts/bump-version.sh major

# 同一个脚本，靠 --mobile 选目标文件（Config/VersionMobile.xcconfig）。
print-version-mobile:
	@scripts/bump-version.sh --mobile print

set-version-mobile:
	@[ "$(origin VERSION)" = "command line" ] || { echo 'Usage: make set-version-mobile VERSION=x.y.z' >&2; exit 1; }
	@scripts/bump-version.sh --mobile set "$(VERSION)"

bump-patch-mobile:
	@scripts/bump-version.sh --mobile patch

bump-minor-mobile:
	@scripts/bump-version.sh --mobile minor

bump-major-mobile:
	@scripts/bump-version.sh --mobile major

build:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(SIGNING_ARGS) \
		build

# Archive with automatic signing (development); the Developer ID profile + re-signing
# happen at the export-app step. Kept separate so a failed export does not waste the build.
archive:
	rm -rf "$(ARCHIVE_PATH)"
	xcodebuild archive \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "generic/platform=macOS" \
		-archivePath "$(ARCHIVE_PATH)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-skipPackagePluginValidation \
		$(PACKAGE_ARGS) \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic \
		DEVELOPMENT_TEAM=$(TEAM_ID) \
		ENABLE_HARDENED_RUNTIME=YES

# Export a Developer ID-signed, notarizable app (profile minted/embedded for the app target).
export-app: archive
	rm -rf "$(EXPORT_DIR)"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>method</key><string>developer-id</string>' \
		'	<key>teamID</key><string>$(TEAM_ID)</string>' \
		'	<key>signingStyle</key><string>automatic</string>' \
		'</dict>' \
		'</plist>' > "$(EXPORT_OPTIONS)"
	xcodebuild -exportArchive \
		-archivePath "$(ARCHIVE_PATH)" \
		-exportPath "$(EXPORT_DIR)" \
		-exportOptionsPlist "$(EXPORT_OPTIONS)" \
		-allowProvisioningUpdates
	test -d "$(EXPORT_APP)"
	@printf '%s\n' "Exported Developer ID app: $(EXPORT_APP)"

test:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

# iOS/iPadOS：宿主是 uTermMobile.app，跑在模拟器上。测试 bundle 靠 TEST_HOST 取符号，
# Frameworks 阶段是空的（见 uTermMobileTests/README.md）。
# 不要加 CODE_SIGNING_ALLOWED=NO —— 模拟器走 ad-hoc 签名，entitlements 不挡路。
test-mobile:
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(MOBILE_SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(MOBILE_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

# 命令行客户端的离线自测：起一个假的 Unix socket 服务端，把每个子命令跑一遍
# （请求编码 / 输出格式化 / 退出码映射）。不需要 Xcode，也不需要 uTerm 在跑。
check-cli:
	python3 scripts/utermctl --help >/dev/null
	python3 scripts/utermctl-selftest.py

# 技能构建产物闸：app 包内的 Resources/Skills/*/SKILL.md 与两份 utermctl 必须与仓库文件
# 逐字节一致（构建阶段「Copy utermctl CLI and Skills」没漏、没坏），外加安装 / 自动对齐的
# 行为测试 —— 只有这两个测试类挡着。发版前跑一次（release skill 已接进去）。
check-skills: check-cli
	xcodebuild build-for-testing \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO
	xcodebuild test-without-building \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO \
		-only-testing:uTermTests/SkillDefinitionTests \
		-only-testing:uTermTests/SkillInstallerTests

clean:
	rm -rf "$(BUILD_DIR)"

# 比对 SwiftData @Model 与已部署的 CloudKit schema（发版前必跑，见 scripts/check-cloudkit-schema.py 头注释）。
# 需要 CloudKit Management Token：xcrun cktool save-token --type management
#
# ChatSession / ChatMessageRecord 这两个 @Model 已搬进 uAppKit 的 AgentKit，不在本仓库源码树里。
# 脚本只扫给它的根，漏掉这一个根 = 容器注册的 10 个类型里有 2 个不设防（而且恰恰是历史上漂得最多的
# 两个），所以这里把 SPM checkout 一并喂进去；找不到 checkout 就**报错退出**，不做「少扫两个类型也算过」
# 的降级——硬门宁可吵也不要假绿。
CLOUDKIT_AGENTKIT_ROOT ?= $(firstword $(wildcard \
	$(BUILD_DIR)/DerivedData/SourcePackages/checkouts/uAppKit/Sources/AgentKit \
	$(HOME)/Library/Developer/Xcode/DerivedData/uTerm-*/SourcePackages/checkouts/uAppKit/Sources/AgentKit))

check-cloudkit-schema:
	@if [ -z "$(CLOUDKIT_AGENTKIT_ROOT)" ]; then \
		echo "error: 找不到 uAppKit 的 AgentKit 源码（ChatSession / ChatMessageRecord 在那里）。"; \
		echo "       先构建一次让 SwiftPM 拉下 checkout，或显式传："; \
		echo "       make check-cloudkit-schema CLOUDKIT_AGENTKIT_ROOT=/path/to/uAppKit/Sources/AgentKit"; \
		exit 2; \
	fi
	python3 scripts/check-cloudkit-schema.py --team-id "$(TEAM_ID)" \
		--source-root uTerm --source-root uTermMobile \
		--source-root "$(CLOUDKIT_AGENTKIT_ROOT)"

dmg-background:
	mkdir -p "$(BUILD_DIR)"
	python3 scripts/generate-dmg-background.py "$(DMG_BG)"

dmg: export-app dmg-background
	test -d "$(EXPORT_APP)"
	rm -f "$(DMG_PATH)" "$(DMG_RW)"
	hdiutil detach "$(DMG_MOUNT)" 2>/dev/null || true
	hdiutil create -size 200m -fs HFS+ -volname "$(APP_NAME)" "$(DMG_RW)"
	hdiutil attach "$(DMG_RW)" -noautoopen -mountpoint "$(DMG_MOUNT)"
	cp -R "$(EXPORT_APP)" "$(DMG_MOUNT)/"
	ln -s /Applications "$(DMG_MOUNT)/Applications"
	mkdir -p "$(DMG_MOUNT)/.background"
	cp "$(DMG_BG)" "$(DMG_MOUNT)/.background/"
	osascript scripts/dmg-window.applescript "$(APP_NAME)"
	swift scripts/set-volume-icon.swift "$(EXPORT_APP)/Contents/Resources/AppIcon.icns" "$(DMG_MOUNT)"
	sync
	hdiutil detach "$(DMG_MOUNT)"
	hdiutil convert "$(DMG_RW)" -format UDZO -o "$(DMG_PATH)"
	rm -f "$(DMG_RW)"
	@printf '%s\n' "Created DMG: $(DMG_PATH)"

sign-release-app: build
	@if [ -z "$(CODE_SIGN_IDENTITY)" ]; then \
		printf '%s\n' 'Skipping release signing because CODE_SIGN_IDENTITY is empty.'; \
	else \
		scripts/sign-release-app.sh "$(APP_PATH)" "$(CODE_SIGN_IDENTITY)"; \
	fi

install: build
	test -d "$(APP_PATH)"
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(APP_PATH)" "$(INSTALLED_APP)"
	"$(LSREGISTER)" -f "$(INSTALLED_APP)"
	@printf '%s\n' "Installed: $(INSTALLED_APP)"

verify:
	test -d "$(EXPORT_APP)"
	codesign --verify --deep --strict --verbose=2 "$(EXPORT_APP)"
	@spctl --assess --type execute --verbose "$(EXPORT_APP)" 2>&1 || \
		printf '%s\n' 'Gatekeeper rejected the app. Ensure Xcode is signed in to an Apple ID with a "Developer ID Application" certificate for TEAM_ID, then re-run make release.'
	@if [ -f "$(DMG_PATH)" ]; then \
		spctl --assess --type open --verbose "$(DMG_PATH)" 2>&1 || \
		printf '%s\n' 'DMG Gatekeeper assessment pending (expected before notarize+staple).'; \
	fi

verify-distribution-signing:
	test -d "$(EXPORT_APP)"
	python3 scripts/verify-background-launcher.py "$(EXPORT_APP)" "uTermBackgroundLauncher"
	codesign --verify --deep --strict --verbose=4 "$(EXPORT_APP)"
	@sign_info=$$(codesign -dv --verbose=4 "$(EXPORT_APP)" 2>&1); \
	if ! printf '%s\n' "$$sign_info" | grep -q 'Authority=Developer ID Application'; then \
		printf '%s\n' 'ERROR: Exported app is not signed with a Developer ID Application certificate.'; \
		printf '%s\n' '  The release flow uses automatic developer-id signing via xcodebuild -exportArchive.'; \
		printf '%s\n' '  Ensure Xcode is signed in to an Apple ID with a "Developer ID Application"'; \
		printf '%s\n' "  certificate for TEAM_ID=$(TEAM_ID), then re-run make release."; \
		printf '%s\n' "$$sign_info" | grep '^Authority=' || true; \
		exit 1; \
	fi

notarize: verify-distribution-signing
	@if [ -z "$(NOTARY_PROFILE)" ]; then printf '%s\n' 'ERROR: NOTARY_PROFILE is required.'; exit 1; fi
	test -f "$(DMG_PATH)"
	mkdir -p "$(BUILD_DIR)"
	xcrun notarytool submit "$(DMG_PATH)" \
		--keychain-profile "$(NOTARY_PROFILE)" \
		--wait \
		--output-format json > "$(NOTARY_RESULT)"
	@python3 -c 'import json, sys; data=json.load(open(sys.argv[1])); status=data.get("status"); sid=data.get("id"); print(f"Notary status: {status}"); print(f"Submission ID: {sid}") if sid else None; sys.exit(0 if status == "Accepted" else 1)' "$(NOTARY_RESULT)"

staple:
	test -f "$(DMG_PATH)"
	xcrun stapler staple "$(DMG_PATH)"
	xcrun stapler validate "$(DMG_PATH)"

# --- iOS / TestFlight ------------------------------------------------------
#
# 与 macOS 一样分两步：archive 用 automatic 开发签名（不带分发 profile），真正的
# 分发签名在 export 时重签。分开的好处同样是「export 失败不浪费这次编译」。
# 前置条件（本机做不了，出错时看 .claude/skills/release/SKILL.md 的 iOS 分支）：
#   - 认证二选一：Xcode 登录了对 TEAM_ID 有 App Store Connect 权限的 Apple ID，
#     或 .env 里配好 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH（见上面的 MOBILE_ASC_AUTH）。
#     API key 这条路 archive / export / upload 三步都会用，证书与 profile 由
#     -allowProvisioningUpdates 自动签发，本机不需要登录任何账号；
#   - App Store Connect 里已有 bundle id com.uozi.uTerm 的应用记录（iOS 与 macOS 共用同一个
#     bundle id com.uozi.uTerm，进同一个 App Store Connect 记录，即通用购买形态）；
#   - 团队 TEAM_ID 下有 Apple Distribution 证书（没有时 API key 会自动签发一张）；
#   - App ID 已开 iCloud（容器 iCloud.com.uozi.uTerm）与 Push Notifications 能力，
#     否则 automatic signing 拉到的 profile 缺能力，export 会在重签这一步失败。
archive-mobile:
	rm -rf "$(MOBILE_ARCHIVE_PATH)"
	mkdir -p "$(MOBILE_BUILD_DIR)"
	@set -e; \
	$(MOBILE_ASC_AUTH); \
	set -x; \
	xcodebuild archive \
		-project "$(PROJECT)" \
		-scheme "$(MOBILE_SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "generic/platform=iOS" \
		-archivePath "$(MOBILE_ARCHIVE_PATH)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-skipPackagePluginValidation \
		$(MOBILE_PACKAGE_ARGS) \
		-allowProvisioningUpdates $$auth \
		CODE_SIGN_STYLE=Automatic \
		DEVELOPMENT_TEAM=$(TEAM_ID)
	test -d "$(MOBILE_ARCHIVE_APP)"
	@printf '%s\n' "Archived: $(MOBILE_ARCHIVE_PATH)"
	@plutil -p "$(MOBILE_ARCHIVE_APP)/Info.plist" | grep -E 'CFBundleShortVersionString|CFBundleVersion|ITSAppUsesNonExemptEncryption'
	@have="$$(plutil -extract CFBundleVersion raw -o - "$(MOBILE_ARCHIVE_APP)/Info.plist")"; \
	want="$(BUILD_NUMBER)"; \
	if [ "$$have" != "$$want" ]; then \
		printf '%s\n' "ERROR: CFBundleVersion=$$have but make print-build=$$want."; \
		printf '%s\n' '  The uTermMobile "Set Build Number" Run Script did not take effect'; \
		printf '%s\n' '  (check ENABLE_USER_SCRIPT_SANDBOXING=NO on the uTermMobile target), or HEAD moved mid-build.'; \
		exit 1; \
	fi; \
	printf '%s\n' "Build number OK: CFBundleVersion=$$have"

# 导出 App Store 分发签名的 .ipa 到 build/mobile/export/（不上传）。
export-mobile: archive-mobile
	rm -rf "$(MOBILE_EXPORT_DIR)"
	@set -e; \
	$(MOBILE_ASC_AUTH); \
	set -x; \
	$(MOBILE_EXPORT_PATH_FIX) xcodebuild -exportArchive \
		-archivePath "$(MOBILE_ARCHIVE_PATH)" \
		-exportPath "$(MOBILE_EXPORT_DIR)" \
		-exportOptionsPlist "$(MOBILE_EXPORT_OPTIONS)" \
		-allowProvisioningUpdates $$auth
	test -f "$(MOBILE_IPA)"
	@printf '%s\n' "Exported App Store ipa: $(MOBILE_IPA)"
	$(MAKE) verify-mobile-signing

# 分发签名闸门（对应 macOS 的 verify-distribution-signing）。三条：
#   1. Authority=Apple Distribution —— 拿到的不是开发证书；
#   2. entitlements 里 aps-environment=production —— 源文件写的是 development，
#      Xcode 在 App Store 导出时按 profile 翻成 production；没翻说明拿到的 profile 不对，
#      装到 TestFlight 上推送注册会失败（CloudKit 同步随之退化）；
#   3. iCloud 容器 iCloud.com.uozi.uTerm 仍在 —— profile 缺 iCloud 能力时会被悄悄剥掉。
verify-mobile-signing:
	test -f "$(MOBILE_IPA)"
	rm -rf "$(MOBILE_VERIFY_DIR)"
	mkdir -p "$(MOBILE_VERIFY_DIR)"
	unzip -q "$(MOBILE_IPA)" -d "$(MOBILE_VERIFY_DIR)"
	@app="$(MOBILE_VERIFY_DIR)/Payload/$(MOBILE_APP_NAME).app"; \
	ents="$(MOBILE_VERIFY_DIR)/entitlements.plist"; \
	test -d "$$app"; \
	sign_info=$$(codesign -dv --verbose=4 "$$app" 2>&1); \
	printf '%s\n' "$$sign_info" | grep '^Authority=' || true; \
	if ! printf '%s\n' "$$sign_info" | grep -q 'Authority=Apple Distribution'; then \
		printf '%s\n' 'ERROR: the exported ipa is not signed with an Apple Distribution certificate.'; \
		printf '%s\n' "  Ensure Xcode is signed in to an Apple ID with an \"Apple Distribution\" certificate for TEAM_ID=$(TEAM_ID)."; \
		exit 1; \
	fi; \
	codesign -d --entitlements - --xml "$$app" > "$$ents" 2>/dev/null || true; \
	plutil -lint "$$ents" >/dev/null 2>&1 || codesign -d --entitlements :- "$$app" > "$$ents" 2>/dev/null; \
	aps=$$(plutil -extract 'aps-environment' raw -o - "$$ents" 2>/dev/null || true); \
	printf '%s\n' "aps-environment=$$aps"; \
	if [ "$$aps" != "production" ]; then \
		printf '%s\n' 'ERROR: aps-environment is not "production" in the exported ipa.'; \
		printf '%s\n' '  TestFlight/App Store builds need the production APNs environment; the source'; \
		printf '%s\n' '  uTermMobile/uTermMobile.entitlements says development and Xcode rewrites it at'; \
		printf '%s\n' '  App Store export time. Not rewritten => the profile is not an App Store profile,'; \
		printf '%s\n' '  or the App ID has no Push Notifications capability.'; \
		exit 1; \
	fi; \
	if ! grep -q 'iCloud.com.uozi.uTerm' "$$ents"; then \
		printf '%s\n' 'ERROR: the iCloud container iCloud.com.uozi.uTerm is missing from the signed entitlements.'; \
		printf '%s\n' '  The App ID needs the iCloud/CloudKit capability, otherwise sync with the macOS app breaks.'; \
		exit 1; \
	fi; \
	printf '%s\n' 'iCloud container OK: iCloud.com.uozi.uTerm'; \
	printf '%s\n' "Distribution signing OK: $(MOBILE_IPA)"

# 上传 archive 到 App Store Connect（TestFlight）。认证同 archive / export，走共用的
# MOBILE_ASC_AUTH：.env 里的 API key 优先，没有则回退到 Xcode 已登录的 Apple ID
# （会话过期时 xcodebuild 会自己报认证失败）。
upload-mobile:
	test -d "$(MOBILE_ARCHIVE_PATH)"
	mkdir -p "$(MOBILE_UPLOAD_DIR)"
	@set -e; \
	$(MOBILE_ASC_AUTH); \
	set -x; \
	$(MOBILE_EXPORT_PATH_FIX) xcodebuild -exportArchive \
		-archivePath "$(MOBILE_ARCHIVE_PATH)" \
		-exportPath "$(MOBILE_UPLOAD_DIR)" \
		-exportOptionsPlist "$(MOBILE_UPLOAD_OPTIONS)" \
		-allowProvisioningUpdates $$auth
	@printf '%s\n' "Uploaded $(MOBILE_APP_NAME) $(MOBILE_VERSION) (build $(BUILD_NUMBER)) to App Store Connect."

# NOTES=<markdown> 时发分组通告（markdown_v2：标题 + 版本/渠道行 + 四组），
# 不给就退回一句话「已上传 TestFlight」。NOTES 缺省取 MOBILE_NOTES_PATH（存在才算）。
notify-mobile:
	scripts/notify-wecom.sh \
		--platform ios \
		--version "$(MOBILE_VERSION)" \
		--build "$(BUILD_NUMBER)" \
		$(if $(NOTES),--notes-file "$(NOTES)")

# 把同一份分组日志写进 TestFlight 的「测试信息 / What to Test」。
# .env 配了 ASC_KEY_* 就走 App Store Connect API 自动写入（会等构建处理完），
# 没配就把纯文本打印出来让人手动粘贴——两种情况都算成功，不卡发版。
testflight-notes-mobile:
	@[ -n "$(NOTES)" ] || { printf '%s\n' 'Usage: make testflight-notes-mobile NOTES=<notes.md>' >&2; \
		printf '%s\n' '  (缺省会找 $(MOBILE_NOTES_PATH))' >&2; exit 1; }
	scripts/testflight-notes.sh \
		--version "$(MOBILE_VERSION)" \
		--build "$(BUILD_NUMBER)" \
		--notes-file "$(NOTES)"

# iOS 没有 Sparkle / OSS 这一段：产物直接交给 App Store Connect，用户从 TestFlight 更新。
# 顺序写死成串行的 $(MAKE) 调用（不靠先决条件的次序），因为上传必须排在导出之后、
# 通告必须排在上传之后。NOTES 给了才写 TestFlight 测试信息。
release-mobile:
	$(MAKE) export-mobile
	$(MAKE) upload-mobile
	$(MAKE) notify-mobile NOTES="$(NOTES)"
	@if [ -n "$(NOTES)" ]; then $(MAKE) testflight-notes-mobile NOTES="$(NOTES)"; \
	else printf '%s\n' 'No NOTES=<markdown>; skipped the TestFlight "What to Test" step.'; fi

# iOS 的 tag 前缀是 mobile-v，与 macOS 的 v<VERSION> 分开（两套版本号会撞车）。
# Tags are always annotated (`git tag -a … -m`). A bare `git tag` breaks under the
# user's global `tag.gpgsign = true`: git then insists on a tag message, aborts
# with "no tag message?", and the old recipe still printed "Created tag …" and
# exited 0, so the later `git push origin <tag>` failed with "src refspec … does
# not match any" (hit on 2026-09-11 releasing uTermMobile 1.1.0). Override the
# message with TAG_MESSAGE="…"; the default is "release <tag>".
TAG_MESSAGE ?=

tag-mobile:
	@t="mobile-v$(MOBILE_VERSION)"; m="$(TAG_MESSAGE)"; [ -n "$$m" ] || m="release $$t"; \
	if git rev-parse "$$t" >/dev/null 2>&1; then \
		printf '%s\n' "Tag $$t already exists, skipping."; \
	else \
		git tag -a "$$t" -m "$$m" || exit 1; \
		printf '%s\n' "Created tag $$t. Push with: git push origin $$t"; \
	fi

tag:
	@t="v$(VERSION)"; m="$(TAG_MESSAGE)"; [ -n "$$m" ] || m="release $$t"; \
	if git rev-parse "$$t" >/dev/null 2>&1; then \
		printf '%s\n' "Tag $$t already exists, skipping."; \
	else \
		git tag -a "$$t" -m "$$m" || exit 1; \
		printf '%s\n' "Created tag $$t. Push with: git push origin $$t"; \
	fi

# The release artifact is produced by archive + export with AUTOMATIC developer-id
# signing (tied to the Xcode-logged-in Apple ID + TEAM_ID); CODE_SIGN_IDENTITY /
# SIGNING_ARGS do NOT affect it (they only feed the non-release `build`/`sign-release-app`
# targets). So the real gate is `verify-distribution-signing`, which greps the exported
# app's codesign output for "Authority=Developer ID Application" after export.
release: clean dmg verify-distribution-signing verify notarize staple

sparkle-tools:
	@if [ -x "$(GENERATE_APPCAST)" ]; then \
		printf '%s\n' "Sparkle tools already present: $(SPARKLE_DIR)"; \
	else \
		printf '%s\n' "Downloading Sparkle $(SPARKLE_VERSION)..."; \
		mkdir -p "$(SPARKLE_DIR)"; \
		curl -fL "$(SPARKLE_URL)" -o "$(BUILD_DIR)/$(SPARKLE_TARBALL)"; \
		tar -xJf "$(BUILD_DIR)/$(SPARKLE_TARBALL)" -C "$(SPARKLE_DIR)"; \
		rm -f "$(BUILD_DIR)/$(SPARKLE_TARBALL)"; \
		test -x "$(GENERATE_APPCAST)" || { printf '%s\n' 'ERROR: generate_appcast not found.'; exit 1; }; \
		printf '%s\n' "Sparkle tools installed: $(SPARKLE_BIN)"; \
	fi

sparkle-keys: sparkle-tools
	@printf '%s\n' 'Generating the Sparkle EdDSA keypair (one-time).'
	@printf '%s\n' 'Private key -> macOS keychain; paste the public key into INFOPLIST_KEY_SUPublicEDKey.'
	"$(GENERATE_KEYS)"

appcast: sparkle-tools
	@if [ ! -f "$(ENV_FILE)" ]; then printf '%s\n' 'ERROR: .env not found. Copy .env.example to .env.'; exit 1; fi
	test -f "$(DMG_PATH)"
	mkdir -p "$(APPCAST_DIR)"
	rm -f "$(APPCAST_DIR)"/*.dmg "$(APPCAST_DIR)/appcast.xml"
	cp "$(DMG_PATH)" "$(APPCAST_DIR)/$(APPCAST_DMG_NAME)"
	@if [ -f "$(APPCAST_DIR)/$(LEGACY_RELEASE_NOTES_NAME)" ]; then \
		cp "$(APPCAST_DIR)/$(LEGACY_RELEASE_NOTES_NAME)" "$(APPCAST_DIR)/$(APPCAST_RELEASE_NOTES_NAME)"; \
	fi
	@set -a; . ./$(ENV_FILE); set +a; \
	prefix="$${OSS_PREFIX:-uTerm}"; prefix="$${prefix#/}"; prefix="$${prefix%/}"; \
	endpoint="$${OSS_ENDPOINT#https://}"; endpoint="$${endpoint#http://}"; \
	"$(GENERATE_APPCAST)" "$(APPCAST_DIR)/" \
		--download-url-prefix "https://$$OSS_BUCKET.$$endpoint/$$prefix/"
	@printf '%s\n' "Generated appcast: $(APPCAST_DIR)/appcast.xml"

publish:
	scripts/upload-oss.sh

notify:
	scripts/notify-wecom.sh \
		--version "$(VERSION)" \
		--build "$(BUILD_NUMBER)" \
		--url "https://$$(. ./$(ENV_FILE); echo $$OSS_BUCKET).$$(. ./$(ENV_FILE); echo $${OSS_ENDPOINT#https://}|sed 's#http://##')/$$(. ./$(ENV_FILE); echo $${OSS_PREFIX:-uTerm})/$(APPCAST_DMG_NAME)"

distribute: release sparkle-tools appcast publish notify

dry-run:
	$(MAKE) -n sparkle-tools sparkle-keys appcast publish
	ENV_FILE=.env.example scripts/upload-oss.sh --dry-run
	$(MAKE) -n archive-mobile export-mobile upload-mobile notify-mobile
