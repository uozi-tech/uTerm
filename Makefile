SHELL := /bin/sh

APP_NAME := uTerm
PROJECT := uTerm.xcodeproj
SCHEME := uTerm
CONFIGURATION ?= Release
TEST_CONFIGURATION ?= Debug
DESTINATION ?= platform=macOS

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

INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Sparkle auto-update / OSS publishing
SPARKLE_VERSION ?= 2.6.4
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
# Build id; matches the "Set Build Number" Run Script (git commit count).
BUILD_NUMBER ?= $(shell git rev-list --count HEAD)
APPCAST_DMG_NAME := $(APP_NAME)-$(VERSION)-$(BUILD_NUMBER).dmg
APPCAST_RELEASE_NOTES_NAME := $(APP_NAME)-$(VERSION)-$(BUILD_NUMBER).html
LEGACY_RELEASE_NOTES_NAME := $(APP_NAME)-$(VERSION).html

.PHONY: help list print-version set-version bump-patch bump-minor bump-major \
	build archive export-app test clean dmg dmg-background sign-release-app install verify \
	verify-distribution-signing notarize staple \
	release tag notify sparkle-tools sparkle-keys appcast publish distribute dry-run

help:
	@printf '%s\n' 'uTerm packaging commands:'
	@printf '%s\n' ''
	@printf '%s\n' '  make print-version                     Print current MARKETING_VERSION'
	@printf '%s\n' '  make set-version VERSION=x.y.z         Set the semantic version'
	@printf '%s\n' '  make bump-patch|bump-minor|bump-major  Increment the semantic version'
	@printf '%s\n' '  make build                             Build the macOS app in Release mode'
	@printf '%s\n' '  make archive                           Archive the app (automatic signing)'
	@printf '%s\n' '  make export-app                        Export a Developer ID-signed app from the archive'
	@printf '%s\n' '  make test                              Run tests with xcodebuild'
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

list:
	xcodebuild -list -project "$(PROJECT)"

print-version:
	@scripts/bump-version.sh print

set-version:
	@[ "$(origin VERSION)" = "command line" ] || { echo 'Usage: make set-version VERSION=x.y.z' >&2; exit 1; }
	@scripts/bump-version.sh set "$(VERSION)"

bump-patch:
	@scripts/bump-version.sh patch

bump-minor:
	@scripts/bump-version.sh minor

bump-major:
	@scripts/bump-version.sh major

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

clean:
	rm -rf "$(BUILD_DIR)"

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

tag:
	@v="$(VERSION)"; \
	if git rev-parse "v$$v" >/dev/null 2>&1; then \
		printf '%s\n' "Tag v$$v already exists, skipping."; \
	else \
		git tag "v$$v"; \
		printf '%s\n' "Created tag v$$v. Push with: git push origin v$$v"; \
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
