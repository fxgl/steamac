# クラッシュレポート、アップデート、ゲーム統計

[English](../privacy-and-updates.md) · [Русский](../ru/privacy-and-updates.md) · [简体中文](../zh/privacy-and-updates.md) · **日本語**

← [マニュアル](README.md)

## クラッシュレポート (Sentry)

ランチャーは、クラッシュレポートといくつかのエラーを開発者自身の Sentry サーバー
(`sentry.fxgam.es`、SwiftPM 経由の sentry-cocoa 9.30.0 SDK) に送信します。デフォルトで有効です。無効にするには、
Settings → General、初回起動時のウィンドウ、または Create SteamOS Disk ウィンドウにある **Send crash reports and diagnostics** チェックボックスを
使います (“What is sent” リンクで下の一覧が表示されます)。無効にすると、
SDK はまったく起動せず、ネットワーク接続も一切行いません (すでにディスクに保存されたレポートは
そのまま残り、送信されません)。1 回の起動だけ無効にする場合: `--no-crash-reports` または `STEAMAC_SENTRY=0`。

送信されるもの:

- スーパーバイザーと VM プロセスのクラッシュ (シグナル/abort、未処理の例外): 原因、スレッドの
  スタック、読み込まれたライブラリの一覧。Metal/MoltenVK のアサート、libkrun/virglrenderer の
  abort、libkrun の C API を通じて伝わった Rust のパニックも含みます。VM プロセスのクラッシュレポートは
  次回の VM 起動時に送信されます。捕捉されなかった Objective-C の例外は、`CPPExceptionTerminate` の下ではなく
  その理由 (stderr からの最初の throw のメッセージとスタック) でグループ化されます (STEAMAC-58)。
- いくつかのエラー (フィンガープリントごと・プロセスごとに 1 回まで、全体の上限あり。同じ
  フィンガープリントは少なくとも 1 日、シェーダーのコンパイルエラーは 30 日間は再送信されません):
  ゲストの GPU コンテキストが致命的状態/デバイスロストになった (vkr の “fatal decoder state”、“device lost”)、MoltenVK の
  パイプラインのコンパイルエラー (`[mvk-error] … compile failed`。MoltenVK が MSL ソースを出力した場合
  (`[mvk-msl] …`: 最初の 40 行とエラー付近の行)、それはブレッドクラムではなく extra の `msl_source` で送信されます。
  失敗したシェーダー全体は最大 256 KiB まで、スクラブされたうえで `.metal`
  ファイルとして添付されます。1 プロセスあたり異なるシェーダーは最大 2 つで、内容のハッシュで重複排除されます (STEAMAC-AD)。vkr の
  “pipeline … creation failed on host” の行はブレッドクラムのみです)、
  libkrun の Rust パニック (`thread … panicked at`)、ディスクの初期プロビジョニングの失敗 (`provision
  failed`)、ディスク作成の失敗、予期しない VM の終了 (ユーザーがシャットダウンを要求していないのに
  0 以外の終了コードまたはシグナルで終了)、アイドルインジケーターの “SteamOS is not responding”。VM
  プロセスのクラッシュでは、スーパーバイザーのレポートに macOS 自身によるそのクラッシュレポート
  (`~/Library/Logs/DiagnosticReports/steamac-vm-*.ips`、pid で照合) が加わります: タイトルにクラッシュ箇所、
  `crash_site` タグ (レポートはこれでグループ化されます)、extra の `macos_crash_report` に例外、
  Application Specific Information の行 (ヒープ破損のトラップでの libmalloc のメッセージ)、
  クラッシュしたスレッドの最初の 16 フレーム (ライブラリ名とシンボル名)。同じ要約がセッション
  ログにも書き込まれるため、クラッシュ後の Report a Problem には、クラッシュレポートがオフでもクラッシュ箇所が含まれます (STEAMAC-BC)。
  応答なしのレポートには `stall_history` が含まれます: 最大 32 個の 1 秒ごとの GPU コマンドカウンター、ハートビートの経過時間、
  ゲストの稼働時間/負荷、プロセスの CPU 時間、ホストのポーリング間隔のサンプルで、パフォーマンス統計が
  オフでも含まれます (STEAMAC-8)。エージェントのハートビートが途絶えただけでは、ゲスト全体や GPU がハングしたことの証明にはなりません。
  GPU アクティビティ、VM メモリ、ホストスレッドのスナップショットはそれぞれ別に上限があります。スレッドの状態と CPU の
  推定値は証拠であり、バックトレースでも GPU デッドロックの証明でもありません。履歴にはホストの
  アクティブ化、キーウィンドウ、ウィンドウの表示/遮蔽も記録されます。“Still working” はゲストのハートビートが
  生きていることを意味し、ゲームが進行中であることやシェーダーをコンパイル中であることの証明にはなりません。VM 終了のレポートには、
  macOS のクラッシュレポートが添付されなかった理由 (時間内に書き込まれなかった、読めなかった、不完全だった、別の pid だった) が記載されます。
  アイドルインジケーターが 10 秒続くと、ハートビートが生きている場合も含めて同じサンプルが一度
  ログに記録されるため、Report a Problem はパフォーマンス統計を有効にしなくてもゲームの停止を診断できます。
  ホストのスケジューリングの空白 (ランチャー自体が数秒間実行されない) の後は、検出器はその空白をゲストのハングとして数える代わりに、
  報告する前に新しいハートビートの期間を監視します。
- SIGTERM/SIGINT/SIGHUP による VM の終了 (ログアウト、`kill`、ハンドラーのインストール前の ^C) は
  クラッシュではありません: ログに 1 行残るだけで、イベントも Report a Problem ウィンドウもありません。SIGPIPE も同様です (両方の
  プロセスがこれを無視します: 閉じた出力パイプ (ターミナル、またはスーパーバイザーが kill された後の
  スーパーバイザーの stderr チャネル) は書き込みが失敗するだけです。その場合 VM プロセスは
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` にログを書くか行を破棄し、ゲストの
  シャットダウン完了を待ちます。STEAMAC-10)。SIGKILL は
  警告レベルの `vm-killed` イベント “VM process killed (SIGKILL — memory pressure or force quit)” を生成します: 
  カーネルがメモリのために kill したかどうか (jetsam、スーパーバイザーの kqueue からの `NOTE_EXIT_DETAIL`)、
  VM メモリと終了時/ピーク時の VM プロセスのフットプリント、ホストの `vm_stat` の数値 (free/compressed/wired、
  swap)、`kern.memorystatus_level`、起動以降のメモリプレッシャーレベルの履歴
  (遷移はログにも書き込まれます: `memory pressure: …`)。アプリメニューの Force Quit (または
  2 回目のシャットダウン要求) は要求された終了であり、レポートにはなりません: VM プロセスはステータス 3 で終了し、
  スーパーバイザーは `user-exit` マーカーファイルなしでそれを認識します (Mac のディスクがいっぱいだとマーカーを
  書き込めなかったため、STEAMAC-15)。
  カーネルのメモリによる kill のフラグは、SIGKILL の不明な発生元とは別に報告されます (フラグがないことは
  Force Quit を意味しません)。VM と Mac のメモリに対するピーク時のフットプリントと、サンプリングされた最も高い
  メモリプレッシャーも、macOS が通知したレベルだけでなく報告されます (STEAMAC-S)。
  `memory_history` は、終了前の最大 2 分間の VM フットプリントとホストのメモリのサンプル (10 秒ごと) を
  追加します。レポート時の別のスナップショットは、VM メモリがすでに解放されているため終了後のものとしてラベル付けされます。
  GPU の致命的エラーと SIGKILL のレポートには、VM プロセスの最近の GPU/ハートビートの履歴と、プロセス、Metal、
  Vulkan の割り当て、共有メモリのスナップショットが加わります。これらのカウンターは重複しており、合計ではありません。ディスクが使用中のため
  拒否された 2 つ目の VM はステータス 4 で終了します: 説明が表示されるだけで、レポートはありません。
- すべてのイベントには、ランチャーの stderr の最後の ~200 行がブレッドクラムとして (`[steamac-vm]`、
  `[mvk-*]`、libkrun/virglrenderer の警告、起動の各段階)、そしてタグが含まれます: バージョン
  (`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`)、環境、`build_kind` タグ:
  `release` は公証付きの `dist.sh` ビルドのみ (Info.plist の `SteamacDistTeamID` があり、かつ
  実行中のコードの署名がそのチームの Developer ID であることを `SecCodeCheckValidity` で確認)、
  `source-build` はそれ以外の `.app` (`bundle.sh`、アドホック署名/再署名したコピー、`dist.sh --no-notarize`)、
  `development` はバンドル外の `work/out/steamac-vm` です。さらに macOS、Mac のモデル、GPU、vCPU/RAM、ディスプレイ
  モード、libkrun / virglrenderer / MoltenVK のビルド UUID、`MVK_PATCH_REVISION`、カーネルのバージョン、
  SteamOS の BUILD_ID とレイヤーのリリース (initramfs の行から)、ゲストでフォーカスされているゲームの `appid`
  (フォーカスされている間)、ランダムなインストール ID。

送信されないもの: ゲストのコンソール (hvc0)、ユーザー名とコンピューター名 (`/Users/<name>` → `~`、名前とホスト名は
伏せられます)、IP アドレス (`sendDefaultPii=false`、サーバーは IP アドレスを公開しません)、ロケール/タイム
ゾーン、Steam アカウント、ゲームのタイトル (App ID のみ)、ファイル。スーパーバイザーは自身の stderr を
チャネル経由で流す (すべては引き続きターミナル/ログに表示されます) ため、クラッシュした
VM プロセスの最後の行も把握できます。

テスト: `--sentry-test-event` (スーパーバイザーと VM プロセスからのテストイベント。VM プロセスは
保留中のクラッシュレポートも送信して終了します)、`--sentry-test-crash abort|segv|metal|panic|kill|term|shader`
(VM プロセスがクラッシュします: `abort()` は C の呼び出し内、`EXC_BAD_ACCESS` は `memset` 内、Metal のアサート、長すぎる
カーネルコマンドラインによる `krun_start_enter` での Rust パニック。`panic` には `--kernel` と、
必要に応じて `--initrd` が必要です。`kill`/`term` は VM プロセスが SIGKILL (`vm-killed`
レポート) または SIGTERM (レポートもウィンドウもなし) で自身を kill します。`shader` は MoltenVK のコンパイルエラーの例を
`[mvk-msl]` と vkr の行付きで出力して終了します)。これらのイベントには `environment=development` と
`test=true` タグが付きます。`STEAMAC_SENTRY_DEBUG=1` は SDK のデバッグログ (サーバーの応答) を出力します。

シンボル: `build.sh` は `steamac-vm` と同梱ライブラリの dSYM を `work/out/dSYMs` に置きます (libkrun、
virglrenderer、MoltenVK は DWARF なしでビルドされ、シンボルテーブルのみを含みます)。`dist.sh` は
それらとアプリが同梱するすべての Mach-O (実行ファイル、Frameworks、Resources 内のヘルパー。それぞれが
`sentry-cli debug-files check` に合格する必要があります) を `sentry-cli --url https://sentry.fxgam.es debug-files upload --wait` でアップロードし、
dSYM を `work/out/dist/FX-Steam-Launcher-<version>-dSYMs` として保存します。公証付きビルドには
`SENTRY_AUTH_TOKEN`、`SENTRY_ORG`、`SENTRY_PROJECT` が必要です (署名前に確認されます。`--no-sentry-upload` で
省略できます): 1.9 はアップロードなしでリリースされ、`steamac-vm` と libkrun のクラッシュはシンボル化されないままでした。

## アップデートの確認

リリース版はアプリ内で自身をアップデートします (Sparkle)。それ以外のビルドは GitHub の最新リリースを確認し、
DMG を提示します。どちらも VM ウィンドウの隣にある同じウィンドウを使い (画面に余裕があれば VM ウィンドウの上には重ならず、
フォーカスも奪いません。キーボードとキャプチャされたマウスは VM のままです)、アプリメニューの **Check for
Updates…** 項目 (バージョンが見つかると New バッジ付きの “Update Available: X.Y…”)、そして Settings → General の **Check for
updates at startup** チェックボックス (すぐに反映されます) も共通です。

**アプリ内アップデート (リリース版)。** リリース版 (`dist.sh` がフィードとその EdDSA 公開鍵を
Info.plist に入れます) は [Sparkle](https://sparkle-project.org) 2.10.1 (`Contents/Frameworks/Sparkle.framework`、
XPC サービスなし: アプリはサンドボックス化されていません) を、独自の UI を上記のウィンドウに置き換えて実行します。
チェックボックスがオンの間は、セッション中も含めて最大 6 時間に 1 回 `https://fxgl.github.io/steamac/appcast.xml` を
取得します。フィードは全体として署名され、各アップデートにも独自の EdDSA 署名があり、どちらも
何かを展開する前にアプリ内の鍵で確認されます (`SURequireSignedFeed`、
`SUVerifyUpdateBeforeExtraction`)。Sparkle は新しいアプリのコード署名が一致することも要求します。
より新しい macOS (または別の Mac) が必要なバージョンは提示されません。メニューからの確認ではその理由が表示されます。新しい
バージョンでは、そのリリースノートと **Install Update** (バックグラウンドでダウンロードします。SteamOS は
動作を続け、**Hide** でウィンドウを閉じ、**Cancel** でダウンロードを中止します。その後 Sparkle のインストーラーが
準備します)、**Skip This Version**、**Remind Me Later** が表示されます。準備ができたアップデートでは **Install and Relaunch** を選べます:
SteamOS は Shut Down SteamOS とまったく同じようにシャットダウンし (電源キー、最大 180 秒、強制終了は決してしません)、その後
Sparkle のインストーラーが実行中のプロセスの外からアプリを置き換えて再び開きます。また
**Install on Quit** (ウィンドウも閉じます) では、ランチャーが終了したときにアップデートがインストールされます。デルタ
アップデート (変更されたファイルのみ) は、フィードにインストール済みのバージョン用のものがあれば使われ、なければ完全な DMG が使われます。

VM プロセスが Sparkle をホストします (NSApplication を実行しているのはこのプロセスだけです)。終了は決して
AppKit を経由せず (ゲストの電源が切れ、libkrun がプロセスを終了します)、スーパーバイザーはゲストの再起動後に
バンドルから新しい VM プロセスを起動しますが、これはそれを置き換えるインストーラーと競合します。そのため、
アップデートの準備中は VM プロセスが実行ディレクトリに `update` マーカーを残し、スーパーバイザーは二度と
起動しません。SteamOS の再起動 (SteamOS からまたは Restart VM) は Install and Relaunch になります。Sparkle 自身の
終了要求 (ランチャーが開始したシャットダウンに続くもの) は無視されるため、強制
終了になることはありません。ユーザーによる 2 回目の終了は、これまでどおり強制終了します。

自身を置き換えられないコピーでは、下記の GitHub での確認が使われます (`update: in-app updates
off (…)` とログに記録されます): ソースビルド (`bundle.sh`)、開発用ランチャー、DMG から起動されたアプリや
Gatekeeper によって App Translocation されたアプリ (Applications に移動されていないもの)、読み取り専用ボリューム上のコピー。

プライバシー: Sparkle のリクエストは `fxgl.github.io` (フィード) と GitHub のリリースのダウンロードにのみ送られ、
標準の `User-Agent` (アプリと Sparkle のバージョン) が付きます。システムプロファイル、Mac やユーザーの識別子、
Sentry は含まれません。Sparkle は自身の状態 (最後の確認時刻、スキップしたバージョン) をアプリの defaults (`SU…` キー) に保存します。

**GitHub のリリースの確認 (その他のビルド)。** アプリの起動時 (起動ごとに 1 回、VM の再起動ごとではなく、
起動をまたいでも 6 時間に 1 回まで) に、ランチャーは起動を遅らせることなくバックグラウンドで
`https://api.github.com/repos/fxgl/steamac/releases/latest` から最新リリースを取得し
(認証なし、10 秒のタイムアウト。ドラフトとプレリリースは除外)、その `vX.Y[.Z]` タグを
自身のバージョン (`CFBundleShortVersionString`、数値として比較: 1.3.10 > 1.3.9) と比べます。新しいバージョンが
ある場合、ウィンドウに “FX Steam Launcher X.Y is available — you have …” と、リリースの
説明、そしてボタン **Download** (リリースの `.dmg` をブラウザーで開きます。ない場合はリリースページを
開きます)、**Skip This Version** (このバージョンは起動時に提示されなくなります)、**Remind Me Later**
(次回の確認で再び提示します) が表示されます。メニュー項目はすぐに確認し (6 時間の制限なしで、
スキップしたバージョンも含みます)、“You're up to date” またはエラーを表示します。起動時のネットワークエラーと HTTP エラーは
ログに記録されるだけです (`update: …`)。開発用ランチャー `work/out/steamac-vm` は起動時に確認しません
(メニューは使えます)。ソースビルド (`bundle.sh`) は確認します。

GitHub での確認のプライバシー: リクエストは `api.github.com` (GitHub) にのみ送られ、含まれるのは `User-Agent:
FXSteamLauncher/<version>` だけです (加えて標準の HTTP ヘッダーと、GitHub が
“not modified” と返せるよう前回の応答の ETag)。Mac やユーザーの識別子、Cookie、Sentry は含まれません。確認時刻、ETag、応答、
スキップしたバージョンは設定に保存されます (`updateLastCheck`、`updateETag`、`updateCachedBody`、
`updateCachedURL`、`updateSkippedVersion`)。

テスト: `STEAMAC_UPDATE_URL` は URL を上書きします (リリースの JSON または `/releases` の配列、`http(s)://` または
`file://`。開発用ランチャーでの起動時の確認も有効にします)。`STEAMAC_FAKE_VERSION` は
ランチャーのバージョンを、`STEAMAC_UPDATE_FEED` はアプリ内アップデートの appcast を上書きします。FIFO `--control-fifo`:
`update check|startup|state`、`update press download|skip|later|ok|releases|cancel|hide|install|quit`
(`install` / `quit`: Install and Relaunch / Install on Quit)、`update dump PNG` (ウィンドウと
`-with-vm.png`。後者は画面に表示されるとおり VM ウィンドウと一緒に出力します)。ローカルのフィード:
[配布](building.md#配布-dmg) を参照してください。

## ゲーム統計

どのゲームがどの Mac で起動し、どれだけ速く動くかを、同意したプレイヤーから集め、
<https://fxgl.github.io/steamac/games.html> (`docs/games.html`) で全員に公開しています。

ゲストエージェントは 1 秒ごとのハートビートで Steam のゲームスコープ (`app-steam-app<appid>-*.scope`、
**Pause the game** が凍結するのと同じ cgroup) を監視し、`game-start <appid>`、5 秒ごとの `game-mem <appid>
<anon_kib> <guest_used_kib>` (ゲームの匿名メモリとゲストの使用メモリ)、
`game-proton <appid> <version>` (プレフィックスの `compatdata/<appid>/version`)、その直後に
`game-gfx <appid> dxmt|vulkan` (実際のグラフィックス経路)、そして `game-exit <appid>` を報告します。
`game <appid> <name>` は、起動ごとに各 app id の最初の `game-start` またはフォーカスの後に続きます。ランチャー
(`GameStats.swift`) はゲームの実行 1 回につき 1 つのレポートを作成します: 実行時間とフォーカスしていた時間 (一時停止しておらず、VM が
サスペンドされていない時間)、ウィンドウが一度でも表示されたか、表示までにかかった時間 (ウィンドウのない実行は起動失敗です)、
ゲームがフォーカスしている間のゲストの scanout-0 フラッシュ間隔から求めたフレームレート (平均、
中央値、1% low、1 分あたりの 50 ms を超えるカクつき。1 秒を超える空白は除外します。libkrun の
`present_frame`、`--perf-stats` が報告するのと同じフラッシュ)、ゲーム / ゲストのメモリのピーク、Mac 上の VM
プロセスの `phys_footprint` のピーク、解像度、Proton のバージョン、終了の種類 (`exit`、
`shutdown`、`session`) です。各レポートには Mac (モデル、チップ、P コア数と総コア数、GPU コア数、
RAM、macOS)、VM (vCPU、RAM、Vulkan ドライバー、wmtr、リフレッシュレート、SteamOS のビルド)、
ランチャーのバージョンが含まれます。
新しいセッションと評価のレポートはスキーマ `v:2` を使い、任意で `gfx` (`vulkan` または `dxmt`) と `env`
(「ゲームごとのプロファイル」で説明している許可リスト内の起動ワード、最大 256 文字) を含みます。実際の
グラフィックス経路は `game-gfx` から取得します。評価には最後のセッションのグラフィックス経路と起動ワードを使います。
サービスは v1 (以前に保存されたセッションを含む) も引き続き受け付け、その `gfx`/`env` は NULL として保存します。
不正な v2 の割り当ては HTTP 400 で拒否されます。有効なものは名前順に並べられ、重複した場合は最後のものが優先されます。

すべてのレポートはこの Mac に保存され (`~/Library/Application Support/es.fxgam.steamac/game-stats.json`、
ゲームごとに 20 セッション)、**Settings → Games** に一覧表示されます。**Share
game statistics** がオンになるまで、何も Mac の外には出ません: ウィンドウのある最初のゲームの後、ランチャーは一度だけ、
キーボードやキャプチャされたマウスを奪わない、VM ウィンドウの横のウィンドウで確認します (**Share** / **Don't
Share**)。Settings → Games のスイッチでいつでも変更できます。オンの間は、終了したセッション
と評価が統計サービスに送られます (`POST /v1/sessions`、`POST /v1/ratings`)。以前に記録された
セッションも含まれます。**Share** のチェックがオフのゲームは何も送信せず、その評価は
取り下げられます (`"rating": "none"`)。アップロードは 1 件ずつ行われます。HTTP 400/413 の場合はレポートを破棄し、それ
以外の場合は 10 分後、次のセッション終了時、または次回の起動時に再試行します。

プライバシー: 名前、ユーザー名やコンピューター名、Steam アカウント、ファイル、任意の入力テキストは送信しません (上記の
許可リスト内のグラフィックス起動ワードのみ共有されます)。インストール ID は、
異なる Mac の数の集計とレート制限にのみ使われるランダムな UUID です (クラッシュレポートの ID とは別物です)。
サービスはクライアントのアドレスを一時的なレート制限キーとしてのみ使い、保存することはありません。

このページは集計値のみを公開し、個々のセッションは公開しません。また、各ゲームがテストされたチップを一覧表示します。
構成は、チップ、RAM、Vulkan ドライバー、グラフィックス経路、起動ワードでグループ化されます (`gfx`/`env`。
`wmtr` は互換性のために保持されています)。古い行では、NULL の `gfx` は `wmtr=0` のときは `vulkan` を意味しますが、
`wmtr=1` のときは不明です: DXMT の使用が許可されていても、ゲームが実際にそれを使ったことの証明にはなりません。
**My Mac** フィルターは、訪問者の Mac より性能が高くない Mac からのレポートだけを残します (GPU コア数、
RAM、パフォーマンスコア数がそれぞれ指定値以下。API の `max_gpu_cores`、`max_ram_gb`、
`max_pcores`): そこで動くものはここでも動くはずです。ランチャーの **Open Statistics Page** はこの
Mac の値 (`?chip=…&gpu=…&ram=…&pcores=…`) を渡してフィルターをオンにし、ページはその値を記憶します。

`GET /v1/games/<appid>` は `recommended` も返します (条件を満たすプロファイルがなければ `null`)。
これは同じ My Mac フィルターの範囲内ですべてのチップにわたって `(driver, gfx, env)` をグループ化し、セッションまたは評価全体で
少なくとも 2 つの異なるインストールを必要とします。不明なグラフィックス経路が選ばれることはありません。
スコア = `(well + 0.5 × issues) / total ratings` (評価がなければ 0)。同点の場合は
`launch_rate` が高いもの、次に `early_exit_rate` が低いものを優先し、率が欠けているものは最後になり、その後は
ドライバー/グラフィックス/env の決定的な順序で並べます。結果には、ドライバー、グラフィックス経路、起動ワード、
インストール数/セッション数、評価、平均 FPS の中央値、起動率が含まれます。サイトとランチャーは
推奨を表示しますが、自動的に適用されることはありません。

サービス: `services/game-stats` — D1 データベースを備えた Cloudflare Worker (厳密な検証、
冪等なセッション ID、アドレスごとに 1 分あたり 30 件の POST、インストールごとの 1 日の上限、集計値の
`GET /v1/games` と `GET /v1/games/<appid>` は D1 に 5 分間キャッシュ。Cache API は
`workers.dev` では何もしないためです)。一度だけデプロイします:

```sh
cd services/game-stats && npm install
npx wrangler login
npx wrangler d1 create steamac-game-stats      # put the printed database_id into wrangler.toml
npx wrangler d1 migrations apply steamac-game-stats --remote
npx wrangler deploy                            # prints https://steamac-game-stats.<account>.workers.dev
```
既存のデプロイでは、マイグレーション `0002_profiles.sql` がセッションと評価に `gfx`/`env` を追加し、
v1 のデータを保持したままグループ化のインデックスを更新します。`0003_responses.sql` はレスポンス
キャッシュのテーブルを追加します。`npx wrangler d1 migrations apply steamac-game-stats --remote` は
`npx wrangler deploy` の**前に**実行してください。

Worker の URL は `host/launcher/Info.plist` (`SteamacGameStatsURL`) と `docs/assets/games.js`
(`API`) に記載します。ローカル: `npx wrangler d1 migrations apply steamac-game-stats --local && npx wrangler dev`、
`npm test`。

テスト: `STEAMAC_GAME_STATS_URL` はサービスを上書きし (開発用ランチャー `work/out/steamac-vm` では
アップロードも有効にします。そうでなければ何も送信しません)、`STEAMAC_GAME_STATS_FILE` はローカルファイルを上書きします。
FIFO `--control-fifo`: `guest game-start <appid>` などがトラッカーに入力され、`stats state|flush|ask|dump
PNG|reset-question`、`stats press share|decline`、`settings games` が使えます。
