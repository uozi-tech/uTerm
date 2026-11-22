# uTerm

[简体中文](README.md) | **English** | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

A server workbench for macOS and iOS / iPadOS: SSH terminal, SFTP file browsing and editing, port forwarding, key management,
Quick Commands and Parallel Run across hosts, and an AI assistant. Your phone or another Mac can also remotely control this Mac's
terminals and screen over the local network or a self-hosted relay. The terminal engine is [Ghostty](https://ghostty.org),
integrated as a Swift package through [libghostty-spm](https://github.com/Lakr233/libghostty-spm) (the patched fork lives in `vendor/libghostty-spm`).

## Platforms

- macOS 26 or later (Apple silicon)
- iOS / iPadOS 18 or later
- Interface languages: 简体中文, English, 繁體中文, 日本語, 한국어 (follows the system; on Mac you can pick one separately in Settings › Appearance › Language)

## Building from Source

You need Xcode 27 (or newer), Go (to build the on-host session holder in `holder/`), and a network connection.

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # fill in your own Team ID and bundle id prefix
make engine     # terminal engine: the first run builds it from upstream source (about 15 minutes; downloads Zig and the Ghostty source)
make build      # or: open uTerm.xcodeproj
```

- **Signing**: to sign with your own team, set your Team ID in `Config/Local.xcconfig` and replace `UTERM_BUNDLE_ID` with your own prefix
  (App IDs are unique across all of Apple, and only our team can use `com.uozi.uTerm`). The bundle id of every target, the iCloud container,
  the Keychain access group, and the launchd job name of the remote control process are all derived from this prefix. The remote control process,
  the local terminal helper, and the holder trust each other by being "signed by the same team"; the team ID and identities are read at
  runtime, so no source changes are needed. For the first build, open the project in Xcode and let it register the App ID and iCloud
  container under Signing & Capabilities, or add `-allowProvisioningUpdates` on the command line.
- **Engine**: `vendor/libghostty-spm` is a patched libghostty-spm (patches are listed in its `UTERM-PATCHES.md`). The two xcframeworks
  are not checked in; `make engine` fetches or builds them according to `ENGINE.lock`.
- **In-app updates and one-click relay deployment**: not included in source builds by default (their entry points are hidden automatically).
  If you want them, configure your own update feed and relay release URL in `Config/Local.xcconfig`; see `Config/Local.xcconfig.example`.
- **Distributing a modified version**: replace the app name (`INFOPLIST_KEY_CFBundleDisplayName`) and icon (`AppIcon`). You may not
  publish it under the uTerm name; see [`TRADEMARK.md`](TRADEMARK.md) (in Chinese). Builds you make for your own use don't need these changes.
- **iCloud sync**: the container is `iCloud.<bundle id prefix>` and does not talk to the official release. `Local.xcconfig.example` sets
  the environment to Development: a new container has no schema in Production yet, so sync would fail silently.

## Testing

```sh
make test-fast           # macOS: full suite in parallel, failures re-checked serially
make test-mobile-fast    # iOS Simulator
make test-holder         # on-host session holder (Go)
cd relay && GOWORK=off go test -race ./...   # self-hosted relay
```

## Layout

| Path | Contents |
|---|---|
| `uTerm/` | Code shared by both platforms, plus the macOS app (files not built for iOS are listed in the pbxproj membership exceptions) |
| `uTermMobile/` | iOS / iPadOS views and platform bridging |
| `uTermRemoteHost/`, `uTermShellAgent/`, `uTermHolder/`, `uTermSSH/` | macOS helper processes: remote control, local terminal, session holding, SSH bridge |
| `holder/` | The session holder that runs on hosts (Go; reattaches the shell after a disconnect) |
| `relay/` | Self-hosted relay (Go, TCP relay + STUN); protocol in `relay/PROTOCOL.md`, deployment in `relay/README.md` |
| `skills/`, `scripts/utermctl` | Command-line tool and skills for AI tools |
| `vendor/` | Patched third-party source; each one's `UTERM-PATCHES.md` records what was changed |
| `docs/` | Design documents and research notes |

Project conventions (where shared code goes, the terminal engine, the remote control process, the holder, the CloudKit schema, version numbers, and more)
are written in [`CLAUDE.md`](CLAUDE.md) (in Chinese, as are the other project documents linked below), which is meant for both people and
AI coding tools to read. The shared Swift packages are in [uAppKit](https://github.com/uozi-tech/uAppKit).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Each contributor signs the [CLA](CLA.md) once before their PR can be merged (checked automatically on the PR).
Please report security issues privately as described in [`SECURITY.md`](SECURITY.md).
For the privacy policy, see [`PRIVACY.md`](PRIVACY.md): no accounts, no analytics, and your data stays on your own devices and in your iCloud.

## License

[AGPL-3.0](LICENSE). Licenses for third-party components are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

The license covers the code only, not the "uTerm" name and icon: if you distribute a modified version, you must change the name and icon; see [`TRADEMARK.md`](TRADEMARK.md).
