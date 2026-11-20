SHELL := /bin/sh

# 维护者的内部配置（团队号、签名身份、发版）；没有 internal/ 时跳过，见 CONTRIBUTING.md。
-include internal/config.mk

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
# 默认取 Xcode 27 自带的那台；探针读数按 iOS 27 校准过（uTermMobileTests/README.md「iOS 27 复量」）。
MOBILE_DESTINATION ?= platform=iOS Simulator,name=iPhone 18 Pro

BUILD_DIR := build
DERIVED_DATA := $(BUILD_DIR)/DerivedData
APP_PATH := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

# 公开构建不写死团队号与签名身份：DEVELOPMENT_TEAM 来自 Config/Local.xcconfig（或命令行 TEAM_ID=…），
# CODE_SIGN_IDENTITY 为空时走自动签名。维护者的值在 internal/config.mk。
DEVELOPMENT_TEAM_ARG := $(if $(TEAM_ID),DEVELOPMENT_TEAM=$(TEAM_ID),)
CODE_SIGN_IDENTITY_ARG := $(if $(CODE_SIGN_IDENTITY),CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)",)
CODE_SIGN_STYLE := $(if $(CODE_SIGN_IDENTITY),Manual,Automatic)
TIMESTAMP_ARG := $(if $(CODE_SIGN_IDENTITY),OTHER_CODE_SIGN_FLAGS=--timestamp,)
ENTITLEMENTS_ARG := $(if $(CODE_SIGN_IDENTITY),CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO,)
SIGNING_ARGS := CODE_SIGN_STYLE=$(CODE_SIGN_STYLE) ENABLE_HARDENED_RUNTIME=YES $(DEVELOPMENT_TEAM_ARG) $(CODE_SIGN_IDENTITY_ARG) $(TIMESTAMP_ARG) $(ENTITLEMENTS_ARG)
# 发布 archive 钉住 Package.resolved：依赖版本可复现，且远端偶发不可达时不会整条失败。
# 想让它照常联网解析依赖就传空值：make archive-mobile MOBILE_PACKAGE_ARGS=
MOBILE_PACKAGE_ARGS ?= -onlyUsePackageVersionsFromResolvedFile
# macOS archive 同理：默认钉在 Package.resolved 上、不联网刷新依赖镜像。uAppKit ≥ 1.4.6 的清单曾用 SSH 形式引用
# swift-nio / swift-log 等，与根工程的 https 形式同名异址，Xcode 的 SwiftPM 在「Updating from …」阶段会互锁挂死（0% CPU、无 git 子进程）。
# 想照常联网解析依赖就传空值：make release PACKAGE_ARGS=
PACKAGE_ARGS ?= -disableAutomaticPackageResolution -skipPackageUpdates
TEST_WORKERS ?= 6
MOBILE_TEST_WORKERS ?= 3
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
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
.DEFAULT_GOAL := help

.PHONY: help test-fast test-relay-e2e test-weak-network relay-dist test-mobile-fast list print-version print-build set-version bump-patch bump-minor bump-major \
	print-version-mobile set-version-mobile bump-patch-mobile bump-minor-mobile bump-major-mobile tag-mobile \
	engine engine-build check-engine holder test-holder test-holder-e2e build test test-mobile check-cli check-skills check-cloudkit-schema clean install \
	sync-strings sync-strings-build check-strings tag

help::
	@printf '%s\n' 'uTerm packaging commands:'
	@printf '%s\n' ''
	@printf '%s\n' '  make print-version                     Print current MARKETING_VERSION'
	@printf '%s\n' '  make print-build                       Print build number (git count + Config/BuildNumberOffset)'
	@printf '%s\n' '  make set-version VERSION=x.y.z         Set the semantic version'
	@printf '%s\n' '  make bump-patch|bump-minor|bump-major  Increment the semantic version'
	@printf '%s\n' '  make engine                            Put the Ghostty xcframeworks into vendor/libghostty-spm/BinaryTarget'
	@printf '%s\n' '  make build                             Build the macOS app in Release mode'
	@printf '%s\n' '  make test                              Run tests with xcodebuild'
	@printf '%s\n' '  make test-mobile                       Run uTermMobileTests on an iOS Simulator'
	@printf '%s\n' '  make test-fast                         Run tests in parallel, recheck failures serially'
	@printf '%s\n' '  make test-mobile-fast                  Same for uTermMobileTests'
	@printf '%s\n' '  make holder                            Build the host session holder (holder/, Go) into the app resources'
	@printf '%s\n' '  make test-holder                       Run the session holder tests (unit + real PTY)'
	@printf '%s\n' '  make test-holder-e2e                   Run the session holder end-to-end tests through a real sshd (docker)'
	@printf '%s\n' '  make test-relay-e2e                    Run end-to-end tests through a real uterm-relay'
	@printf '%s\n' '  make test-weak-network                 Run the remote weak-network matrix, write docs/remote-weak-network-baseline.md'
	@printf '%s\n' '  make relay-dist                        Build uterm-relay for linux amd64/arm64 into build/relay'
	@printf '%s\n' '  make check-cli                         Self-test scripts/utermctl (no Xcode, no uTerm)'
	@printf '%s\n' '  make check-skills                      Run the bundled skills / utermctl tests'
	@printf '%s\n' '  make check-cloudkit-schema             Diff @Model against the deployed CloudKit schema'
	@printf '%s\n' '  make sync-strings                      Build both targets, merge new strings into Localizable.xcstrings'
	@printf '%s\n' '  make check-strings                     Same, but only fail if the catalog is behind the code'
	@printf '%s\n' '  make clean                             Remove build artifacts'
	@printf '%s\n' '  make install                           Install the app to /Applications'
	@printf '%s\n' ''
	@printf '%s\n' '  iOS:'
	@printf '%s\n' '  make print-version-mobile              Print uTermMobile MARKETING_VERSION'
	@printf '%s\n' '  make set-version-mobile VERSION=x.y.z  Set the uTermMobile semantic version'
	@printf '%s\n' '  make bump-{patch,minor,major}-mobile   Increment the uTermMobile semantic version'
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

# 终端引擎（GhosttyKit + libghostty-vt）的两个 xcframework 不进版本库：按 vendor/libghostty-spm/ENGINE.lock 取 zip、
# 校验 sha256、解到 vendor/libghostty-spm/BinaryTarget/。已是清单要的那一份时什么都不做，所以挂在每个会编工程的目标前面。
# zip 从 UTERM_GHOSTTY_ARTIFACTS=<目录> 取（维护者的目录在 internal/config.mk），没有就退到现编。
# `make clean` 只清 build/，不动 vendor/ 下的这两份。
# 取不到 zip（新克隆的仓库、换了机器；fetch 脚本退出码 3）时退到从上游源码现编（约 10–20 分钟，要联网），
# 设 UTERM_GHOSTTY_NO_BUILD=1 就不退、直接失败。
engine:
	@rc=0; scripts/fetch-ghostty-engine.sh || rc=$$?; \
	if [ $$rc -eq 3 ] && [ -z "$$UTERM_GHOSTTY_NO_BUILD" ]; then \
		echo "取不到引擎 zip，改为从上游源码现编（make engine-build）"; \
		scripts/build-ghostty-engine.sh; \
	else exit $$rc; fi

# 从上游源码现编引擎（scripts/build-ghostty-engine.sh），装进 BinaryTarget/，stamp 记成本机现编。
# 默认只编 macOS + iOS；出正式 zip（升级引擎）用 ENGINE_BUILD_ARGS='--platforms macos,ios,maccatalyst,visionos --pack <目录>'。
engine-build:
	@scripts/build-ghostty-engine.sh $(ENGINE_BUILD_ARGS)

# 只核不取：BinaryTarget/ 里不是清单要的那一份就非零退出。
check-engine:
	@scripts/fetch-ghostty-engine.sh --check

# 主机上的会话保持进程（holder/，Go）：编出 linux amd64 / arm64，压好放进 App 的资源目录（不进版本库）。
# 源码没变时什么都不做，所以和 engine 一样挂在每个会编工程的目标前面。需要 Go。
holder:
	@scripts/build-host-holder.sh

# 保持进程自己的测试（单元 + 真 PTY，本机）。
test-holder:
	cd holder && GOWORK=off go vet ./... && GOWORK=off go test -race -count=1 ./...

# 经真实 sshd（docker 容器）的端到端用例；测量延迟 / 吞吐加 UTERM_HOLDER_MEASURE=1。
test-holder-e2e:
	holder/scripts/e2e.sh

build: engine holder
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(SIGNING_ARGS) \
		build

test: engine holder
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		test

# 并行全量，失败用例再串行复核一遍，见 scripts/test-parallel.sh。
test-fast: engine holder
	scripts/test-parallel.sh "$(SCHEME)" "$(DESTINATION)" "$(TEST_WORKERS)" \
		-project "$(PROJECT)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO \
		$(PACKAGE_ARGS)

# 起一个真实的 uterm-relay 跑经它的端到端用例。中继自身的测试：cd relay && GOWORK=off go test ./...
test-relay-e2e: engine holder
	scripts/test-relay-e2e.sh \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO \
		$(PACKAGE_ARGS)

test-weak-network: engine holder
	scripts/test-weak-network.sh \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO \
		$(PACKAGE_ARGS)

# 中继打包：交叉编译两个架构 + SHA256SUMS + latest.json + install.sh，放进 build/relay/，整个目录传到任意静态
# 下载地址即可（UTERM_RELAY_BASE_URL 指向它）。版本取 relay/cmd/uterm-relay/main.go 的 version。
RELAY_VERSION := $(shell sed -n 's/^const version = "\(.*\)"/\1/p' relay/cmd/uterm-relay/main.go)
RELAY_DIST := build/relay

relay-dist:
	@test -n "$(RELAY_VERSION)" || { echo "relay version not found in relay/cmd/uterm-relay/main.go" >&2; exit 1; }
	cd relay && GOWORK=off go test ./... && bash scripts/install.test.sh
	rm -rf "$(RELAY_DIST)" && mkdir -p "$(RELAY_DIST)/$(RELAY_VERSION)"
	for arch in amd64 arm64; do \
		(cd relay && GOWORK=off GOOS=linux GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' \
			-o "../$(RELAY_DIST)/$(RELAY_VERSION)/uterm-relay-linux-$$arch" ./cmd/uterm-relay) || exit 1; \
	done
	cd "$(RELAY_DIST)/$(RELAY_VERSION)" && shasum -a 256 uterm-relay-linux-* > SHA256SUMS
	printf '{ "version": "%s" }\n' "$(RELAY_VERSION)" > "$(RELAY_DIST)/latest.json"
	@# 发布地址写进安装脚本（UTERM_RELAY_BASE_URL：放 latest.json 与各版本二进制的目录）；不给就留占位，脚本运行时要求设环境变量。
	sed 's#@RELAY_BASE_URL@#$(UTERM_RELAY_BASE_URL)#' relay/scripts/install.sh > "$(RELAY_DIST)/install.sh"
	@[ -n "$(UTERM_RELAY_BASE_URL)" ] || printf '%s\n' "note: UTERM_RELAY_BASE_URL is empty; install.sh will ask for it at run time."
	@printf '%s\n' "Built uterm-relay $(RELAY_VERSION) in $(RELAY_DIST)"

test-mobile-fast: engine holder
	scripts/test-parallel.sh "$(MOBILE_SCHEME)" "$(MOBILE_DESTINATION)" "$(MOBILE_TEST_WORKERS)" \
		-project "$(PROJECT)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		-enableCodeCoverage NO \
		$(MOBILE_PACKAGE_ARGS)

# iOS/iPadOS：宿主是 uTermMobile.app，跑在模拟器上。测试 bundle 靠 TEST_HOST 取符号，
# Frameworks 阶段是空的（见 uTermMobileTests/README.md）。
# 不要加 CODE_SIGNING_ALLOWED=NO —— 模拟器走 ad-hoc 签名，entitlements 不挡路。
test-mobile: engine holder
	xcodebuild \
		-project "$(PROJECT)" \
		-scheme "$(MOBILE_SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(MOBILE_DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(MOBILE_PACKAGE_ARGS) \
		test

# 把代码里的文案合进 String Catalog，不用在 Xcode 里按 ⌘B。
# 编译器按 SWIFT_EMIT_LOC_STRINGS 给每个源文件吐 .stringsdata，Xcode 的 IDE 在构建后把它们合进
# .xcstrings——这一步 xcodebuild 不做、xcstringstool sync 会删光未翻译的键，所以用
# scripts/sync-strings.swift 自己合（格式逐字节对齐 Xcode，自测 scripts/sync-strings.test.sh）。
# 两端都要先编一遍：mac-only 文件的文案只有 uTerm 构建才产出，反之亦然；只给一端会把另一端独有的键
# 当成「代码里没了」删掉。构建产物与 make test-fast 共用 DerivedData 的 Debug，通常是增量。
STRINGS_CATALOG := uTerm/Localizable.xcstrings
SYNC_STRINGS_TOOL := $(BUILD_DIR)/tools/sync-strings
STRINGSDATA_MAC := $(DERIVED_DATA)/Build/Intermediates.noindex/uTerm.build/$(TEST_CONFIGURATION)/uTerm.build/Objects-normal
STRINGSDATA_MOBILE := $(DERIVED_DATA)/Build/Intermediates.noindex/uTerm.build/$(TEST_CONFIGURATION)-iphonesimulator/$(MOBILE_SCHEME).build/Objects-normal

$(SYNC_STRINGS_TOOL): scripts/sync-strings.swift
	mkdir -p "$(dir $@)"
	swiftc -O -o "$@" "$<"

sync-strings-build: engine holder
	xcodebuild build -quiet \
		-project "$(PROJECT)" \
		-scheme "$(SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(PACKAGE_ARGS)
	xcodebuild build -quiet \
		-project "$(PROJECT)" \
		-scheme "$(MOBILE_SCHEME)" \
		-configuration "$(TEST_CONFIGURATION)" \
		-destination "generic/platform=iOS Simulator" \
		-derivedDataPath "$(DERIVED_DATA)" \
		$(MOBILE_PACKAGE_ARGS) \
		ARCHS=arm64

sync-strings: sync-strings-build $(SYNC_STRINGS_TOOL)
	"$(SYNC_STRINGS_TOOL)" --catalog "$(STRINGS_CATALOG)" \
		--stringsdata-dir "$(STRINGSDATA_MAC)" --stringsdata-dir "$(STRINGSDATA_MOBILE)"

# 只核不写：目录落后于代码时非零退出（给 CI / 发版前自检用）。
check-strings: sync-strings-build $(SYNC_STRINGS_TOOL)
	"$(SYNC_STRINGS_TOOL)" --catalog "$(STRINGS_CATALOG)" --check \
		--stringsdata-dir "$(STRINGSDATA_MAC)" --stringsdata-dir "$(STRINGSDATA_MOBILE)"

# 命令行客户端的离线自测：起一个假的 Unix socket 服务端，把每个子命令跑一遍
# （请求编码 / 输出格式化 / 退出码映射）。不需要 Xcode，也不需要 uTerm 在跑。
check-cli:
	python3 scripts/utermctl --help >/dev/null
	python3 scripts/utermctl-selftest.py

# 技能构建产物闸：app 包内 Resources/Skills/ 下的文档（SKILL.md 与 references）与两份 utermctl 必须与仓库文件
# 逐字节一致（构建阶段「Copy utermctl CLI and Skills」没漏、没坏），外加安装 / 自动对齐的
# 行为测试 —— 只有这两个测试类挡着。发版前跑一次（release skill 已接进去）。
check-skills: check-cli engine holder
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

install: build
	test -d "$(APP_PATH)"
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED_APP)"
	cp -R "$(APP_PATH)" "$(INSTALLED_APP)"
	"$(LSREGISTER)" -f "$(INSTALLED_APP)"
	@printf '%s\n' "Installed: $(INSTALLED_APP)"

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

# 发版目标（archive / dmg / notarize / release / release-mobile / appcast / publish …）在 internal/release.mk，只有维护者有。
-include internal/release.mk
