<p align="center"><img src="docs/media/icon.png" width="96" height="96" alt=""></p>

<h1 align="center">FX Steam Launcher</h1>

<p align="center">
Valve 公式の ARM64 版 SteamOS（Steam Frame 向けビルド）を Apple Silicon 上の軽量な仮想マシンで実行。<br>
GPU アクセラレーションによる Windows ゲームの動作、幅広いコントローラーへの対応、ネイティブオーディオ。
</p>

<p align="center">
<a href="https://github.com/fxgl/steamac/releases/latest"><b>ダウンロード</b></a> ·
<a href="https://fxgl.github.io/steamac/">ウェブサイト</a> ·
<a href="https://fxgl.github.io/steamac/games.html">ゲーム統計</a> ·
<a href="manual/ja/README.md">マニュアル</a>
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.ru.md">Русский</a> · <a href="README.zh.md">简体中文</a> · <b>日本語</b></p>

![FX Steam Launcher で動作する Steam のゲームパッド向け UI](docs/media/shot-library.jpg)

## インストール

1. [リリースページ](https://github.com/fxgl/steamac/releases/latest)から DMG をダウンロードして開き、
   FX Steam Launcher を「アプリケーション」にドラッグします。アプリは署名済みで、Apple の公証を受けています。
2. アプリを起動して **Create New Disk…** を選び、SteamOS のブランチ、ゲーム用パーティションの容量、
   Steam クライアントを指定します。Valve の SteamOS ライセンスと Steam 利用規約に同意すると、
   ランチャーが Valve の署名済みイメージ（約 4.5 GB）をダウンロードして検証し、ディスクを作成します。
3. Steam にサインインしてゲームをインストールします。Proton 11（ARM64）と FEX は Steam が自動で用意します。

Apple Silicon 搭載の Mac、macOS 15 以降、ディスク作成用に約 20 GB の空き容量が必要です。
ディスクはスパースファイルで、ゲームをインストールするにつれて使用容量が増えます。アップデートはアプリ内で行えます。

## 対応機能

- **DirectX 9/10/11** は DXVK、**DirectX 12** は vkd3d-proton、OpenGL は zink で動作します。
- **x86-64 の Windows および Linux ゲーム**は、ARM64 版 Proton 11 と FEX、Apple のハードウェア TSO で動作します。
- **コントローラー**：Xbox、DualSense（タッチパッド、ジャイロ、アダプティブトリガーごとパススルーも可能）、
  DualShock 4、MFi、Steam Controller に対応し、振動も使えます。視点操作用にマウスをキャプチャできます。
- CoreAudio による**サウンド**（最大 12 チャンネル：5.1、7.1、7.1.4）とマイク入力。
- メモリへの**サスペンド**、**デスクトップモード**、**クリップボード**と**フォルダー**の共有、
  ローカルネットワークでの **Moonlight** ストリーミングと **Steam Remote Play**。
- 2 種類の Vulkan ドライバー：**KosmicKrisp**（Metal 4、macOS 26 以降ではデフォルト）と **MoltenVK**（Metal 3）。

どのゲームがどの程度動作するかは、プレイヤーからの報告をまとめた[ゲーム統計](https://fxgl.github.io/steamac/games.html)で確認できます。

## 制限事項

- DirectX 12 の機能レベル 12_1 やシェーダーモデル 6.6（Unreal Engine 5）を必要とするゲームは起動しません。
- 仮想マシンをブロックするアンチチートを使用したゲームはプレイできません。
- 初めて表示されるエフェクトは Metal がコンパイルする際に一度だけカクつきます（約 50～100 ms）。以後はキャッシュが使われます。

詳細は[ステータスと制限事項](manual/ja/status.md)を参照してください。

## 仕組み

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

libkrun は QEMU を使わず、Hypervisor.framework 上で Valve の署名済み SteamOS イメージを起動します。
SteamOS のルートファイルシステムは変更しないため、Steam Deck と同様に公式の A/B アップデートが機能します。
各コンポーネントとパッチについては[仕組み](manual/ja/architecture.md)を参照してください。

## ソースからのビルド

```sh
git clone https://github.com/fxgl/steamac
cd steamac
./build.sh    # MoltenVK、KosmicKrisp、virglrenderer、libkrun、ランチャー、ゲストカーネル、Mesa、ディスク
./run.sh      # ウィンドウ内で SteamOS を実行
```

Xcode 26 以降、Homebrew、rustup、OrbStack（または arm64 と特権コンテナに対応した Docker）が必要です。
手順の詳細は[ソースからのビルド](manual/ja/building.md)を参照してください。

## マニュアル

| トピック | 内容 |
|---|---|
| [ランチャーの使い方](manual/ja/using.md) | アプリ、アンインストール、言語、Steam クライアント、サインイン |
| [設定](manual/ja/settings.md) | 設定ウィンドウの各タブとゲームごとのプロファイル |
| [コントローラー](manual/ja/controllers.md) | ゲームパッド、DualSense パススルー、Steam Controller、マウスとキーボード |
| [Vulkan ドライバー](manual/ja/vulkan-drivers.md) | MoltenVK と KosmicKrisp の対応機能と切り替え方法 |
| [ストリーミングとリモートプレイ](manual/ja/streaming.md) | LAN、Steam Remote Play、Moonlight |
| [サスペンドとスリープ](manual/ja/suspend-and-sleep.md) | SteamOS のメモリへのサスペンドと SteamOS 自体のスリープ |
| [デスクトップモード](manual/ja/desktop-mode.md) | 仮想マシン内の Plasma デスクトップ |
| [クリップボードと共有フォルダー](manual/ja/clipboard-and-shared-folder.md) | SteamOS とテキスト、画像、Mac 上のフォルダーを共有する方法 |
| [クラッシュレポート、アップデート、ゲーム統計](manual/ja/privacy-and-updates.md) | 送信される情報、送信のタイミング、無効にする方法 |
| [問題の報告](manual/ja/report-a-problem.md) | 問題レポートに含まれる情報と送信方法 |

## コントリビュート

不具合やゲームの動作報告、翻訳、パッチを歓迎します。まずは [CONTRIBUTING.md](CONTRIBUTING.md)（英語）をご覧ください。

## ライセンス

プロジェクトのコードは Apache License 2.0（`LICENSE`）の下でライセンスされています。© 2026 FX GAMES FZ LLC。
例外は `NOTICE` に記載されています。Linux カーネルのパッチと設定は GPL-2.0-only、virglrenderer と Mesa の
パッチは各プロジェクトと同じ MIT、Valve の `deckard-steamvr-session` パッケージから派生した gamescope の
セッションファイル 5 点は MIT © Valve Corporation です。Valve の CA 証明書と `docs/media` 内のスクリーンショットは
プロジェクトのライセンスの対象外です。ライセンスの全文は `LICENSES/` にあります。

SteamOS はプロジェクトに含まれず、同梱して配布することもありません。ユーザーが Valve のライセンスに同意すると、
アプリが Valve のサーバーから署名済みのイメージをダウンロードします
（[Docker を使わない SteamOS ディスクの作成](manual/ja/building.md#docker-を使わない-steamos-ディスクの作成)を参照）。

Steam、Steam のロゴ、SteamOS、Steam Deck、Steam Frame は、米国およびその他の国における Valve Corporation の
商標または登録商標です。このプロジェクトは Valve Corporation と提携しておらず、同社の承認も受けていません。
