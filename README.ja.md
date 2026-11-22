# uTerm

[简体中文](README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md)

macOS と iOS / iPadOS のためのサーバ作業環境です。SSH ターミナル、SFTP によるファイルの閲覧と編集、ポートフォワーディング、鍵の管理、
クイックコマンドと複数ホストでの並列実行、AI アシスタントを備え、スマートフォンや別の Mac から、ローカルネットワークまたはセルフホストのリレーを経由して、
この Mac のターミナルと画面をリモート操作することもできます。ターミナルエンジンは [Ghostty](https://ghostty.org) で、
[libghostty-spm](https://github.com/Lakr233/libghostty-spm) を通じて Swift パッケージとして組み込んでいます（パッチを当てた fork は `vendor/libghostty-spm` にあります）。

## 対応プラットフォーム

- macOS 26 以降（Apple シリコン）
- iOS / iPadOS 18 以降
- 表示言語：简体中文、English、繁體中文、日本語、한국어（システムの設定に従います。Mac では「設定 › 外観 › 言語」で個別に指定できます）

## ソースからビルドする

Xcode 27（またはそれ以降）、Go（ホスト上のセッション保持プロセス `holder/` のビルドに使用）、ネットワーク接続が必要です。

```sh
git clone https://github.com/uozi-tech/uTerm.git && cd uTerm
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 自分の Team ID と bundle id のプレフィックスを記入
make engine     # ターミナルエンジン：初回は上流のソースからビルド（約 15 分、Zig と Ghostty のソースをダウンロード）
make build      # または open uTerm.xcodeproj
```

- **署名**：自分のチームで署名する場合は、`Config/Local.xcconfig` に Team ID を記入し、`UTERM_BUNDLE_ID` を自分のプレフィックスに置き換えてください
  （App ID は Apple 全体で一意で、`com.uozi.uTerm` は私たちのチームしか使えません）。各 target の bundle id、iCloud コンテナ、キーチェーンのアクセスグループ、
  リモート操作プロセスの launchd ジョブ名は、すべてこのプレフィックスから派生します。リモート操作プロセス、ローカルターミナルの補助プロセス、holder は
  「同じチームで署名されていること」で互いを認証し、チーム ID と署名の識別情報は実行時に読み取るため、ソースコードを変更する必要はありません。初回のビルドでは、
  Xcode でプロジェクトを開き、Signing & Capabilities で App ID と iCloud コンテナを登録させるか、コマンドラインに `-allowProvisioningUpdates` を付けてください。
- **エンジン**：`vendor/libghostty-spm` はパッチを当てた libghostty-spm です（パッチの内容は同ディレクトリの `UTERM-PATCHES.md` を参照）。2 つの xcframework はリポジトリに含まれず、
  `make engine` が `ENGINE.lock` に従って取得するか、その場でビルドします。
- **App 内アップデートとリレーのワンクリック設置**：ソースからのビルドでは既定で無効です（入口は自動的に非表示になります）。必要な場合は `Config/Local.xcconfig` に
  自分のアップデート配信元とリレーの公開先を設定してください。`Config/Local.xcconfig.example` を参照してください。
- **改変版の配布**：App 名（`INFOPLIST_KEY_CFBundleDisplayName`）とアイコン（`AppIcon`）を差し替えてください。uTerm の名前で配布することはできません。
  [`TRADEMARK.md`](TRADEMARK.md) を参照してください。自分でビルドして自分で使うだけなら変更は不要です。
- **iCloud 同期**：コンテナは `iCloud.<bundle id のプレフィックス>` になり、正式版とは同期しません。`Local.xcconfig.example` では環境を Development に設定してください。
  新しいコンテナの Production にはまだスキーマがなく、同期が何も言わずに失敗します。

## テスト

```sh
make test-fast           # macOS：全件を並列実行し、失敗したものを直列で再確認
make test-mobile-fast    # iOS シミュレータ
make test-holder         # ホスト上のセッション保持プロセス（Go）
cd relay && GOWORK=off go test -race ./...   # セルフホストのリレー
```

## ディレクトリ構成

| パス | 内容 |
|---|---|
| `uTerm/` | 両プラットフォーム共通のコードと macOS App（iOS でビルドしないファイルは pbxproj の membership exceptions に記載） |
| `uTermMobile/` | iOS / iPadOS のビューとプラットフォーム連携 |
| `uTermRemoteHost/`、`uTermShellAgent/`、`uTermHolder/`、`uTermSSH/` | macOS の補助プロセス：リモート操作、ローカルターミナル、セッション保持、SSH ブリッジ |
| `holder/` | ホスト上のセッション保持プロセス（Go。切断後に再接続してシェルに復帰） |
| `relay/` | セルフホストのリレー（Go、TCP リレー + STUN）。プロトコルは `relay/PROTOCOL.md`、設置方法は `relay/README.md` を参照 |
| `skills/`、`scripts/utermctl` | AI ツール向けのコマンドラインとスキル |
| `vendor/` | パッチを当てたサードパーティのソースコード。変更内容はそれぞれの `UTERM-PATCHES.md` に記録 |
| `docs/` | 設計ドキュメントと調査記録 |

プロジェクトの規約（共通コードの置き場所、ターミナルエンジン、リモート操作プロセス、holder、CloudKit スキーマ、バージョン番号など）は [`CLAUDE.md`](CLAUDE.md) にまとめています
（このリポジトリのドキュメントは中国語で書かれています）。人が読むためのものであると同時に、AI コーディングツールが読むためのものでもあります。共通の Swift パッケージは [uAppKit](https://github.com/uozi-tech/uAppKit) にあります。

## コントリビューション

[`CONTRIBUTING.md`](CONTRIBUTING.md) を参照してください。PR をマージする前に、各コントリビューターは一度 [CLA](CLA.md) に署名する必要があります（PR 上で自動的にチェックされます）。
セキュリティ上の問題は、[`SECURITY.md`](SECURITY.md) の手順に従って非公開で報告してください。
プライバシーポリシーは [`PRIVACY.md`](PRIVACY.md) を参照してください。アカウントはなく、統計データも収集しません。データはあなた自身のデバイスと iCloud にあります。

## ライセンス

[AGPL-3.0](LICENSE)。サードパーティのコンポーネントそれぞれのライセンスは [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照してください。

ライセンスが対象とするのはコードのみで、「uTerm」の名称とアイコンは含まれません。改変版を配布する場合は名称とアイコンを差し替えてください。[`TRADEMARK.md`](TRADEMARK.md) を参照してください。
