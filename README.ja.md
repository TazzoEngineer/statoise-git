# Statoise Git

*[English](README.md) | 日本語*

[![Build](https://github.com/TazzoEngineer/statoise-git/actions/workflows/build.yml/badge.svg)](https://github.com/TazzoEngineer/statoise-git/actions/workflows/build.yml)

macOS 向けの Finder 統合 Git クライアント。TortoiseGit と同じ使い勝手を、AppKit ネイティブアプリで。

Statoise Git は Git を普段の作業場所に持ち込みます。Finder でファイルやフォルダを右クリックすれば
コミット・差分表示・履歴閲覧ができ、各ファイルの状態はアイコンオーバーレイで表示されます。
ターミナルを開く必要はありません。

> 現在は early / preview 段階です。ビルドは ad-hoc 署名のため、初回起動時に macOS の承認が必要です。

## 機能

- **Finder コンテキストメニュー** — Commit / Diff / Log / Pull / Push / Fetch / Add /
  Stash（保存・メッセージ付き保存・pop・一覧）/ Submodule update / Reset --hard / Clean -xdf
- **アイコンオーバーレイ** — Normal / Modified / Added / Deleted / Conflict / Unversioned /
  Ignored / Locked / Read-only のバッジを Finder 上のファイル・フォルダに表示
- **コミットウィンドウ** — ステージ操作、ファイル単位の差分表示、ファイル一覧からの revert と削除、
  「変更なしも表示」トグルとファイル数表示
- **ログウィンドウ** — コミットグラフ描画、コミット単位のファイル一覧、ファイル単位の差分、ファイル履歴
- **差分ウィンドウ** — 内蔵ビューアに加え、外部 diff ツール（Meld など）の起動に対応
- **サブモジュール対応** — 状態表示・差分・コミットのいずれもサブモジュールのパスを正しく処理
- **環境設定** — 監視対象リポジトリの登録、`git` バイナリと外部 diff ツールの指定、
  システム設定の「ログイン項目と機能拡張」への直接ジャンプ

## 動作環境

- macOS 13.0 以降
- Xcode 15 以降
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）—
  Xcode プロジェクトは `StatoiseGit/project.yml` から生成されます

## ビルドと実行

```sh
make build     # Xcode プロジェクトを生成してビルド（Debug）
make run       # ビルドし ~/Applications にインストールして起動
make release   # Release 構成でビルド
make dmg       # Release をビルドして .dmg を作成
make clean     # ビルド成果物を削除
```

初回起動後、**システム設定 → 一般 → ログイン項目と機能拡張 → Finder 機能拡張** で
拡張を有効にし、アプリの環境設定でリポジトリを登録してください。

## 仕組み

2 つのバンドルが連携して動作します。

- `Statoise Git.app`（`com.statoisegit.app`）— UI 本体。環境設定・コミット・ログ・差分の各ウィンドウ
- `StatoiseGitFinderExtension`（`com.statoisegit.app.FinderExtension`）— バッジ描画と
  コンテキストメニューを担当する、サンドボックス内の FinderSync 拡張

拡張はサンドボックス内にあり自身で Git を実行できないため、メニューを選択すると
`statoisegit://<action>?path=…` という URL を開き、本体アプリがそれを処理します
（`commit`, `log`, `diff`, `pull`, `push`, `fetch`, `add`, `stash-save`, `stash-save-prompt`,
`stash-pop`, `stash-list`, `reset-hard`, `clean-xdf`, `submodule-update`）。
状態の算出は本体アプリ側で行い、`/Users/Shared/StatoiseGitShared` 配下のキャッシュディレクトリを
介して拡張と共有しています。

## リポジトリ構成

```
StatoiseGit/
  project.yml                  XcodeGen のプロジェクト定義
  Sources/App/                 AppKit の UI、URL スキームのルーティング、Git エラーダイアログ
  Sources/GitOperations/       GitCommandRunner — git 実行はすべてここに集約
  Sources/Shared/              RepositoryPreferences — アプリと拡張の共有状態
  FinderExtension/             FinderSync 拡張とそのオーバーレイアイコン
  Resources/                   アプリアイコンとオーバーレイアイコン
  Tests/                       git 操作のユニットテスト
  UITests/                     コミットウィンドウの UI テスト
scripts/                       アイコン生成、DMG 作成、インストール補助
.github/workflows/build.yml    CI: 生成・ビルド・ユニットテスト・成果物パッケージ
Makefile                       日常的なビルドコマンド
```

## ライセンス

[MIT](LICENSE)
