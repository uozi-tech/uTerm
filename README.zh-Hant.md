# uTerm

[简体中文](README.md) | [English](README.en.md) | **繁體中文** | [日本語](README.ja.md) | [한국어](README.ko.md)

macOS 與 iOS／iPadOS 上的伺服器工作台：SSH 終端機、SFTP 檔案瀏覽與編輯、連接埠轉送、金鑰管理、快速指令與多主機平行執行、
AI 助理；手機或另一台 Mac 還能透過區域網路或自架中繼，遠端控制這台 Mac 的終端機與螢幕。終端機引擎是 [Ghostty](https://ghostty.org)，
透過 [libghostty-spm](https://github.com/Lakr233/libghostty-spm) 以 Swift 套件接入（含補丁的 fork 位於 `vendor/libghostty-spm`）。

## 平台

- macOS 26 或以上版本（Apple 晶片）
- iOS／iPadOS 18 或以上版本
- 介面語言：简体中文、English、繁體中文、日本語、한국어（跟隨系統；在 Mac 上可於「設定 › 外觀 › 語言」另外指定）

## 從原始碼建置

需要 Xcode 27（或更新版本）、Go（用來編譯主機上的工作階段保持程序 `holder/`）以及網路連線。

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填入你自己的 Team ID 與 bundle id 前綴
make engine     # 終端機引擎：第一次會從上游原始碼編譯（約 15 分鐘，會下載 Zig 與 Ghostty 原始碼）
make build      # 或是 open uTerm.xcodeproj
```

- **簽署**：以你自己的團隊簽署時，在 `Config/Local.xcconfig` 中填入 Team ID，並把 `UTERM_BUNDLE_ID` 換成你自己的前綴
  （App ID 在 Apple 全域唯一，`com.uozi.uTerm` 只有我們的團隊能用）。各 target 的 bundle id、iCloud 容器、鑰匙圈存取群組、
  遠端控制處理程序的 launchd 任務名稱都由這個前綴衍生；遠端控制處理程序、本機終端機的輔助程序與 holder 之間以「同一團隊簽署」互相認可，
  團隊 ID 與身分都在執行時讀取，不必修改原始碼。第一次建置時用 Xcode 打開專案，在 Signing & Capabilities 中讓它註冊 App ID
  與 iCloud 容器，或在命令列加上 `-allowProvisioningUpdates`。
- **引擎**：`vendor/libghostty-spm` 是含補丁的 libghostty-spm（補丁見其中的 `UTERM-PATCHES.md`），兩個 xcframework 不納入版本控制，
  由 `make engine` 依照 `ENGINE.lock` 取得或現場編譯。
- **App 內更新與中繼一鍵部署**：從原始碼建置的版本預設沒有這兩項（入口會自動隱藏）。如果需要，請在 `Config/Local.xcconfig` 中設定你自己的更新來源與中繼
  發布位址，詳見 `Config/Local.xcconfig.example`。
- **散布修改過的版本**：請更換 App 名稱（`INFOPLIST_KEY_CFBundleDisplayName`）與圖像（`AppIcon`），不得以 uTerm 的名義發布，
  詳見 [`TRADEMARK.md`](TRADEMARK.md)。自己編譯、自己使用則不必更改。
- **iCloud 同步**：容器是 `iCloud.<bundle id 前綴>`，與正式版不互通。`Local.xcconfig.example` 中已把環境設為 Development：
  新容器的 Production 環境裡還沒有 schema，同步會無聲失敗。

## 測試

```sh
make test-fast           # macOS：平行執行全部測試，失敗的再逐一重新核對
make test-mobile-fast    # iOS 模擬器
make test-holder         # 主機工作階段保持程序（Go）
cd relay && GOWORK=off go test -race ./...   # 自架中繼
```

## 目錄

| 路徑 | 內容 |
|---|---|
| `uTerm/` | 兩端共用的程式碼與 macOS App（iOS 不編譯的檔案列在 pbxproj 的 membership exceptions 中） |
| `uTermMobile/` | iOS／iPadOS 的視圖與平台橋接 |
| `uTermRemoteHost/`、`uTermShellAgent/`、`uTermHolder/`、`uTermSSH/` | macOS 的輔助程序：遠端控制、本機終端機、工作階段保持、SSH 橋接 |
| `holder/` | 主機上的工作階段保持程序（Go，斷線重連後接回 shell） |
| `relay/` | 自架中繼（Go，TCP 中繼 + STUN），協定見 `relay/PROTOCOL.md`，部署見 `relay/README.md` |
| `skills/`、`scripts/utermctl` | 給 AI 工具使用的命令列與技能 |
| `vendor/` | 含補丁的第三方原始碼，各自的 `UTERM-PATCHES.md` 記錄了修改內容 |
| `docs/` | 設計文件與研究紀錄 |

專案慣例（共用程式碼的放法、終端機引擎、遠端控制處理程序、holder、CloudKit schema、版本號……）寫在 [`CLAUDE.md`](CLAUDE.md)
（本 README 以外的專案文件皆以簡體中文撰寫），既是給人看的，也是給 AI 程式設計工具讀的。共用的 Swift 套件在 [uAppKit](https://github.com/uozi-tech/uAppKit)。

## 參與貢獻

請見 [`CONTRIBUTING.md`](CONTRIBUTING.md)。合併 PR 之前，每位貢獻者都要簽署一次 [CLA](CLA.md)（PR 中會自動檢查）。
安全性問題請依照 [`SECURITY.md`](SECURITY.md) 私下回報。
隱私權政策見 [`PRIVACY.md`](PRIVACY.md)：沒有帳號、不收集分析資料，資料都在你自己的裝置與 iCloud 中。

## 授權條款

[AGPL-3.0](LICENSE)。第三方元件各自的授權條款見 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

授權條款只涵蓋程式碼，不包括「uTerm」名稱與圖像：散布修改過的版本時須更換名稱和圖像，詳見 [`TRADEMARK.md`](TRADEMARK.md)。
