# サスペンドとスリープ

[English](../suspend-and-sleep.md) · [Русский](../ru/suspend-and-sleep.md) · [简体中文](../zh/suspend-and-sleep.md) · **日本語**

← [マニュアル](README.md)

## サスペンド

**方法:** Settings → General → “When closing the window” → **Suspend** — ウィンドウを閉じると、
VM はシャットダウンする代わりにサスペンドします。または **FX Steam Launcher → Suspend** (Ctrl+Cmd+S、
ゲストがキーボードを使っているときも動作します) を使います。`krun_pause` (libkrun パッチ 0016) がすべての vCPU と
ゲストの音声を止め、ウィンドウは非表示になり、メニューバーに ⏸ アイコンが表示されます: “SteamOS suspended”、
いつからか、メモリの使用量、**Resume**、**Shut Down SteamOS**。サスペンド中の VM は
CPU を使いません (約 0%)。Mac はスリープできます。

**再開:** Dock アイコンをクリックする、アプリを再起動する (Finder、`open`、`open -a`)、メニューバーの
アイコンを使う、またはメニューから **Resume** を選択します。ウィンドウが戻り (フルスクリーンモードだった場合は
それも含めて)、マウスのキャプチャも元に戻ります。“Resuming…” の進捗表示は、ゲストの最初の新しい
フレームまで表示されます (静止した Steam のインターフェースのようにゲストの GPU がアイドルなら 0.5 秒、最大 2.5 秒)。

**時計:** ゲストのモノトニック時計は一時停止を認識しません (libkrun は QEMU と同様に仮想タイマーをずらします)
— sched_ext スケジューラーやウォッチドッグは発火しません。再開の直後に、
`fx-clock-sync.service` が壁時計を設定します (レイヤー内の root サービスで、同じ
`fx-progress-agent clock-sync` バイナリを使い、ポートが現れると udev が起動します): ランチャーは
自身の時刻を `time <unix_ns>` として virtio ポート `fx.clock` に書き込み、サービスは
CLOCK_REALTIME だけを調整します (`clock_adjtime(ADJ_SETOFFSET)`、進める方向のみ、1 秒より大きく遅れている場合のみ)。
その調整の後は、timesyncd が自力で同期します。

**終了:** サスペンド中に Cmd+Q / Dock → Quit を選ぶと、“SteamOS is suspended” と表示されます: **Shut Down SteamOS**
(ゲストが再開して通常どおりシャットダウンします) または **Cancel** (サスペンドしたままです)。Mac のログアウト、
再起動、シャットダウンでは確認は表示されません。

**制限事項:** 状態は FX Steam Launcher の実行中にメモリ上にだけ存在します — ディスクには
保存されません (ゲストのメモリとホストの GPU の状態 — virglrenderer、MoltenVK、Metal — は
シリアライズされません)。アプリの終了、アプリのクラッシュ、ログアウト、Mac のシャットダウンは、通常の
SteamOS のシャットダウンになります。保存していないゲームの進行状況は失われます。VM の
サスペンド中も、ゲストのメモリはすべて占有されたままです。ゲストのネットワーク接続 (オンラインゲーム、ダウンロード) は、
長い一時停止の後に切断され、再接続されることがあります。

## SteamOS のスリープ

Steam → Power → **Sleep**、Steam のアイドル時の自動スリープ (Settings → Power → “Sleep after”、デフォルトは
1 時間)、ゲスト内の `systemctl suspend` は、ゲストカーネルをスリープさせません (VM には
s2idle を起こすものがありません — 以前の SteamOS はこれでアプリが終了するまでハングしていました)。レイヤーは
`systemd-suspend.service` の `ExecStart` を (`systemd-suspend-then-hibernate` /
`systemd-hybrid-sleep` も同様に。ハイバネーションは `sleep.conf.d` で無効化されています)
`fx-progress-agent sleep` に置き換えます: これは `system-sleep` フック (`pre`) を実行し、
`sleep <action> <token>` を virtio ポート `fx.sleep` に書き込んで応答を待ちます。ランチャーは
VM をサスペンドします (`krun_pause`、Suspend と同様 — CPU 約 0%、Mac はスリープできます) が、ウィンドウは
開いたままで、「SteamOS is sleeping」カードがフレームに重なって表示されます。クリック、キー入力、ゲームパッドのボタン、または Dock
アイコンで起こせます: `krun_resume` の後、`wake <token> <unix_ns>` がゲストに送られ、コマンドが
壁時計を調整し (clock-sync と同様)、`post` フックを実行して終了します — logind が
PrepareForSleep(false) を送り、Steam が起動します。「Waking up…」の進行状況ピルは最初のフレームまで表示されます。
ゲストを起こしたクリックやキー入力はゲストには渡されません。

スリープ中にウィンドウを閉じた場合は “When closing the window” の設定に従います: Suspend はウィンドウを隠します
(その後の Resume でゲストも起こします)。Shut Down / Cmd+Q はゲストを起こし、ゲストのスリープタスクが
完了した後に電源ボタンを押します (`awake <token>`。タスクの実行中は logind がボタンを無視します)。
ポートがない場合 (`--headless`、古いランチャー) は、ゲストのスリープはスリープせずに
失敗します。

`--control-fifo` を使ったテスト用: `close`、`suspend`、`resume` (スリープ中のゲストも起こします)、
`reopen`、`quit`、`wake` (Mac のスリープ解除と同様)、`quit-prompt shutdown|cancel|dump PNG`、
`status open|close|dump PNG|item TITLE`。
