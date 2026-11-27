# 問題の報告

[English](../report-a-problem.md) · [Русский](../ru/report-a-problem.md) · [简体中文](../zh/report-a-problem.md) · **日本語**

← [マニュアル](README.md)

うまく動かない場合は、ランチャーから直接開発者にレポートを送れます:
**Help → Report a Problem…** (またはアプリメニューから)、Settings → General の **Report a Problem…** ボタン、
「SteamOS is not responding…」カードの **Report…** リンク、そして
VM が予期せず終了した (クラッシュ、エラー) 後に表示される「FX Steam Launcher stopped unexpectedly」ウィンドウの
**Report…** ボタンです。ダイアログには次の項目があります:
メールアドレス (必須。開発者が返信できるようこの Mac に記憶されます)、説明 (何をしたか、
何を期待したか、何が起きたか)、添付ファイルのチェックボックス:

- **Include launcher logs** (有効) — このセッションのランチャー、libkrun、virglrenderer、MoltenVK からのメッセージ
  (両方のプロセスの直近約 2 MB) と `perf:`/`stall:` の行。パス `/Users/<name>` → `~` に置き換えられ、
  ユーザー名とコンピューター名、メールアドレス、IP アドレスは伏せられます。
- **Include SteamOS logs (system journal, Steam/Proton logs)** (有効) — このセッションのゲストコンソール (hvc0) と、
  ゲストエージェントが収集した `steamos-logs.tar.gz` アーカイブ: 現在の起動の systemd ジャーナル
  (`journalctl -b`、直近 5000 行、およびユーザージャーナル)、`coredumpctl list`/`info`、
  `dmesg`、`systemctl --failed`、`os-release`、`layer-release`、`/proc/cmdline`、`df`/`free`、
  スレッドの ID/状態/CPU/待機チャネルとコマンド名 (`threads.txt`、コマンドの引数は含みません)、
  Steam クライアントのログの末尾 (`console_log`、`stderr`、`bootstrap_log`、`compat_log`、`connection_log`、
  `webhelper`、`cef_log`、`shader_log`、`steamui_*`、Steam Input の `controller`、`controller_ui`、
  `cloud_log`) と Proton のログ (`PROTON_LOG=1` による `~/steam-*.log`、
  `compatdata` 内のプレフィックスの `version` と `config_info`)、FEX ツールのビルド ID / Steam マニフェスト /
  設定、オプトインの FEX ログ、メモリの制限、メモリ/IO/CPU の負荷 (`/proc/pressure/*`)、
  `/proc/vmstat` と 3 回分の `vmstat` のサンプル、SteamVR とストリーミングのログの末尾 (`vrserver`、
  `vrcompositor`、`vrmonitor`、`vrwebhelper`、`vrstream`、`streaming_log`、それぞれ 256 KiB、IP アドレスは
  伏せられます)、そして American Truck
  Simulator の `game.log.txt` の直近 512 KiB。ATS のエミュレーターのクラッシュでは、Steam の起動オプションを
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%` に設定し、再現させてから報告してください。
  収集処理はそのログの直近 512 KiB を含めます。その後、起動オプションは削除してください。
  1 MiB を超える Proton のログは、スクラブ済みの先頭 1 MiB の起動部分の抜粋と末尾の
  1 MiB として収集され、中間は省略されます。これにより、クラッシュハンドラーの大量の出力があっても
  ランタイムのヘッダーと最初の例外が残ります (STEAMAC-AA)。Desktop Mode のレポートには、`plasmashell`、KWin、Discover が実行中かどうかと、
  許可リスト内のレンダラーのフラグが、プロセスの引数や環境変数の値なしで記録されます (STEAMAC-9P)。ランチャーのログには
  Game Mode の適格性 (実行時とディスク上の Info.plist のキー)、ネイティブフルスクリーンの状態、
  フィルター済みの `gamepolicyd` のメッセージが記録されます (STEAMAC-9V)。
  Proton のログがない場合、Windows ゲーム自体の失敗を確認するには、ゲームの起動オプションに `PROTON_LOG=1 %command%` を設定し、
  1 回再現させて新しいレポートを送る必要があることがアーカイブに記載されます。Unity Player と
  Easy Anti-Cheat のテキストログは、実行中または最後に起動したゲームの Proton プレフィックスと、
  Steam ライブラリ全体で最近変更された 3 つのプレフィックスから収集されます (プレフィックスごとに 256 KiB のログを最大 4 つ、
  プレフィックスの外へのリンクなし、セーブデータやバイナリなし、スクラブ済み)。これらはゲームやその
  アンチチートが動作することを意味するものではありません。
  FEX はエミュレートされたゲームのクラッシュを JIT コードから再送出するため、コアのスタックには
  匿名の AArch64 アドレスしか表示されません。x86_64 コードがどこで異常終了したかを記録するには、
  `~/.local/share/Steam/steamapps/compatdata/<appid>/fex-emu/AppConfig/<executable>.json` (ATS:
  `270880/fex-emu/AppConfig/amtrucks.json`) を作成して
  `{"Config":{"Env":"LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so"}}` と記述し、再現させてから報告してください。
  Steam の起動オプションではこれはできません: FEX の互換ツールが環境から `LD_PRELOAD` を削除するためです。
  SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT が発生すると、ライブラリは x86_64 の RIP、異常発生アドレス、
  レジスター、各フレームのモジュールとオフセット付きのバックトレース、メモリマップを
  `~/.local/state/steamac/fault-report.txt` に書き込みます。ファイルは 256 KiB 未満に収まり、レポートには
  `fex/fault-report.txt` として含まれます。その後、ゲーム自身のハンドラーまたはデフォルトの動作が実行されるため、クラッシュと
  そのコアダンプは変わりません。そのファイルがなければライブラリは読み込まれません。後で削除してください。
  完了したクラッシュのメタデータは、`steamos` のみを対象とする root のフックによってエクスポートされます (root 所有、モード 0640)。
  生のコアは非公開のままで、添付されることはありません。`coredump-pending.txt` はまだ処理中の
  ダンプを示します: レポートはそれを待たないので、完了したらもう一度レポートを送ってください。名前空間を考慮した
  スタックの抽出は、シンボルが利用できる場合に pressure-vessel のライブラリを解決します (FEX の JIT コードは
  シンボル化されないままのことがあります)。コア処理の制限は下げていません: サイズの大きいコアは
  バックトレースを失ってしまい、`Storage=none` でも完全な一時コアが書き込まれるためです。Steam ID (`[U:1:…]`、
  7656119…、`userdata/<n>` のようなアカウント ID)、Steam のアカウント名/ペルソナ名、メールアドレスは、パッケージ化の前に
  プレースホルダーに置き換えられます。`collect-notes.txt` には読み取れたものが一覧表示されます。SSH 経由では、同じスクラブ済みのアーカイブを
  `/usr/lib/steamac/fx-progress-agent collect > /tmp/steamos-logs.tar.gz` で取得できます。
- **Include a screenshot of the VM window** (デフォルトでは無効: 画像に Steam の
  アカウント名やフレンドが写る可能性があります)。

`system-info.txt` (アプリと macOS のバージョン、Mac のモデル、GPU、libkrun/virglrenderer/MoltenVK のビルド UUID、
カーネル、SteamOS の BUILD_ID、レイヤーのリリース、ディスクサイズ、VM の設定、収集時のメモ) と `settings.txt`
(保存された設定とコマンドラインでの上書き。SSH のパスワードはキーチェーンに保存され、レポートに含まれることはなく、
ゲームのタイトルも含まれません) は常に添付されます。**Show What Will Be Sent** はレポートを組み立て、
そのフォルダーを Finder で開きます — 送信されるのはまさにその内容です。

レポートは User Feedback として Sentry (`sentry.fxgam.es`、同じプロジェクト) に送られます: メールアドレス、説明、
このセッションの最新のエラーイベントへのリンク (あれば)、添付ファイルとしてのファイルを 1 つのエンベロープにまとめ、
サーバーのレスポンスを確認できるよう、エンベロープのエンドポイントに直接送信します。クラッシュレポートが
無効でも動作します (ユーザーの明示的な操作です: その場合、SDK とクラッシュハンドラーは起動しません)。添付ファイルは
20 MB に制限されます (まずログの古い部分が切り詰められ、次にスクリーンショットと SteamOS のアーカイブが
除外されます)。HTTP 413 のレスポンスでは、制限を半分にしてレポートを再送します。送信後、
短い Report ID (イベント ID の先頭 8 文字) が表示されます。送信に失敗した場合、フォルダーは
`~/Library/Logs/es.fxgam.steamac/reports/<date>-<ID>/` に残ります (メールアドレスと説明を含む `report.json`
とファイル)。ダイアログには **Retry** と **Reveal in Finder** が表示され、フォルダーをメールで送ることもできます。

仕組み: スーパーバイザーは常に両方のプロセスの stderr をパイプで受け取り、
`/tmp/steamac-<pid>/launcher.log` に書き込みます (タイムスタンプ付き、4 MB でローテーション)。VM プロセスは hvc0
コンソールをその隣の `console.log` に書き込みます。ディレクトリはランチャーの終了時に削除されます。ゲストのログ
は、同じ `fx.progress` ポートを逆方向に使って要求されます: ランチャーが
`collect-logs <id>` を書き込むと、エージェント (セッションのユーザーとして実行され、そのユーザーが読めるものにのみアクセスできます)
が `logs-begin <id> <size>`、`logs <id> <base64>` の行、
`logs-end <id> <sha256>` (または `logs-failed <id> <reason>`) で応答します。ランチャーはアーカイブを組み立て、
そのサイズと SHA-256 を検証します。20 秒以内に応答がない場合やエージェントが実行されていない場合 (ハートビート
なし) は、`system-info.txt` にメモを残したうえで、ゲストのログなしでレポートを送信します。

テスト: `--control-fifo PATH`、コマンド `report open`、`report fill EMAIL TEXT…` (イベントに
`test=true` のタグ付け)、`report include launcher|steamos|screenshot on|off`、`report preview`、`report send`、
`report retry`、`report dsn DSN|default`、`report dump PNG`、`report close`。`STEAMAC_REPORT_DSN`
は DSN を上書きし (失敗時の経路)、`STEAMAC_SENTRY_DEBUG=1` はサーバーのレスポンスを出力します。クラッシュ後の
ウィンドウ: `--sentry-test-crash abort` と `STEAMAC_REPORT_DUMP=<dir>` (ウィンドウとダイアログの PNG を出力し、
その後自動的に閉じます。`STEAMAC_REPORT_TEST_SEND=1` を付けるとテストレポートも送信します)。
