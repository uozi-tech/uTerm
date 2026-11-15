#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	printf '%s\n' "Usage: $0 /path/to/App.app CODE_SIGN_IDENTITY" >&2
	exit 2
fi

app_path=$1
identity=$2
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"

if [ ! -d "$app_path" ]; then
	printf '%s\n' "ERROR: app bundle not found: $app_path" >&2
	exit 1
fi

sign_path() {
	path=$1
	if [ -e "$path" ]; then
		printf '%s\n' "Signing: $path"
		codesign --force --sign "$identity" --timestamp --options runtime "$path"
	fi
}

if [ -d "$sparkle_framework" ]; then
	sign_path "$sparkle_framework/Versions/B/Updater.app"
	sign_path "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc"
	sign_path "$sparkle_framework/Versions/B/XPCServices/Installer.xpc"
	sign_path "$sparkle_framework/Versions/B/Autoupdate"
	sign_path "$sparkle_framework"
fi

sign_path "$app_path/Contents/Helpers/uterm-holder.app"
sign_path "$app_path/Contents/Helpers/uterm-ssh"
sign_path "$app_path/Contents/XPCServices/uTermShellAgent.xpc"
sign_path "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
