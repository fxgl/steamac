# 設定

[English](../settings.md) · [Русский](../ru/settings.md) · [简体中文](../zh/settings.md) · **日本語**

← [マニュアル](README.md)

## 設定ウィンドウ

**FX Steam Launcher → Settings…** (Cmd+,。ゲストがキーボードを使っているときも動作します)。各フィールドには
“applies now” (すぐに反映) または “applies on next start” (次回の VM
起動時に反映) のラベルが付いています。後者のグループで何かを変更すると、下部に **Restart VM to apply** が表示されます:
ゲストは電源ボタン経由で通常どおりシャットダウンし、スーパーバイザーが新しい値で VM を再び起動します
(**Restart VM** メニュー項目からも実行できます)。コマンドラインのフラグは保存された値より優先されますが、
その起動に限ります: フィールドには “overridden by command line
(--cpus 6)” と表示されます。

| タブ | すぐに反映 | 次回起動時 |
|---|---|---|
| General | 起動/シャットダウンのオーバーレイ、GPU アイドル時の “Still working…” インジケーター、“When FX Steam Launcher is in the background”: **Mute sound** (デフォルトでオン: `krun_snd_set_volume(…, mute)` で約 150 ms かけて徐々にフェードアウトし、ウィンドウに戻ると音量が戻ります) と **Pause the game** (デフォルトでオフ: ゲストエージェントはフォーカス中のゲームだけを凍結します — `systemctl --user freeze app-steam-app<appid>-*.scope`、cgroup v2。Steam、ダウンロード、アップデートは動作し続けます。オンラインゲームは切断されることがあります)。エージェントが凍結を確認している間 (`game-frozen`/`game-thawed`)、ウィンドウは暗くなり、“Game paused · Click to resume” カードとタイトルの “— paused” が表示されます。ウィンドウをクリックするとゲームが再開し、そのクリックはゲストに渡されません。クラッシュレポート (`--no-crash-reports`、[クラッシュレポート](privacy-and-updates.md#クラッシュレポート-sentry)を参照)、**Check for updates at startup** (デフォルトでオン、[アップデートの確認](privacy-and-updates.md#アップデートの確認)を参照)、フレーム統計のログ (`--perf-stats`)、**Use the Mac's keyboard layouts in Desktop Mode** (デフォルトでオン、[デスクトップモード](desktop-mode.md#デスクトップモード)を参照) | 起動時のフルスクリーン、**Use the Mac's time zone and clock format** (デフォルトでオン。[ビルドと実行](building.md#ビルドと実行)を参照) |
| Display | ゲストがウィンドウサイズに追従、ウィンドウ右上の Apple の Metal Performance HUD (Ctrl+Cmd+P、View → Show Metal Performance HUD)、**MetalFX super resolution** (デフォルトでオフ): ウィンドウのピクセル数がゲストより多いとき (Retina 画面、拡大縮小された、またはフルスクリーンのウィンドウでは 2 倍)、リニア / ニアレストの拡大の代わりに、Apple の MetalFX 空間アップスケーラーでゲストの画像をウィンドウのピクセルサイズに拡大します。ランチャー内でゲストのフレームに対して実行されるため、すべてのゲームと Steam の UI で動作します | 物理サイズの取得元 (ディスプレイから自動 / DPI / mm — `--dpi`、`--display-mm`)、リフレッシュレート (`--refresh`)、ウィンドウサイズ (`--display`): 1280 × 800 (Steam Deck) から 3840 × 2560 までの標準的な 16:10、16:9、21:9、3:2 の解像度 (ディスプレイに収まらないものには “larger than this screen” と表示され、ウィンドウは従来どおり縮小されます)、“Fit to screen” (ディスプレイに合う最大サイズ、起動のたびに再計算)、または “Custom…” (W × H のフィールド)。**Retina resolution** (任意、デフォルトでオフ): ゲストのディスプレイは、同じ EDID の物理サイズのまま画面のピクセル密度 (ウィンドウのポイント × 画面のバッキングスケール。起動時に取得し、どの辺も 4094 px を超えないようにスケールを下げます) になります。そのため SteamOS は UI を同じサイズまで拡大し、文字がくっきり表示されます。ただしゲームは 4 倍のピクセルを描画し、各フレームのコピーも 4 倍の大きさになります。代わりにおすすめの設定: Retina resolution をオフ + MetalFX super resolution (Retina 画面では 2 倍のアップスケール) |
| Mouse | ゲーム内での自動キャプチャ、ゲームの一覧 (`appmanifest_<appid>.acf` からの名前、Default/Auto/Off、削除) | — |
| Controller | 仮想パッドを操作する物理コントローラー (GameController) (最初に接続されたもの、または選択したもの)、SteamOS にパッドを渡すかどうかと何として見せるか (`--no-gamepad`、`--pad`、[コントローラー](controllers.md#コントローラー)を参照)、DualSense をそのままパススルーするかどうか、追加のコントローラーをプレイヤー 2–4 にするかどうか、A/B と X/Y の入れ替え、スティックのデッドゾーン、ライブ入力テスト | — |
| Sound | 出力デバイス (System default は macOS に追従、または特定の CoreAudio デバイス)、音量/ミュート、Low/Normal/Safe のバッファ — `krun_snd_set_*` 経由 (`dlsym` で検索します。古い libkrun ではフィールドが無効になり、説明が表示されます) | サウンド (`--no-sound`) |
| Games | **Share game statistics** (同意するまでオフ、[ゲーム統計](privacy-and-updates.md#ゲーム統計)を参照)、既知のゲームとセッションが記録されたゲーム: ゲームごとのプロファイル (グラフィックス、Vulkan ドライバー、起動オプション。後述)、セッション、プレイ時間、前回のセッションの FPS / 1% low / ゲームのメモリ / Vulkan ドライバー、任意の評価 (Runs well / Playable with issues / Starts, but unplayable / Does not start)、ゲームごとの **Share** スイッチ | プロファイルによっては Steam または VM の再起動が必要です (後述) |
| Advanced | — | vCPU (`--cpus`)、RAM (`--mem`)、SSH の有効/無効 + ポート (`--ssh-port`、`--no-ssh`) と生成されたパスワード、ネットワーク (`--no-net`)、ディスクイメージ (`--disk`)、Create New Disk…、Steam クライアント (`--steam-client`、[Steam クライアント](using.md#steam-クライアント)を参照)、Vulkan ドライバー (`--vulkan-driver`、[Vulkan ドライバー](vulkan-drivers.md#vulkan-ドライバー)を参照)、Allow DXMT (D3D11 on the Mac's Metal)、実験的機能 (`--wmtr-lib`、`--no-wmtr`、[Vulkan ドライバー](vulkan-drivers.md#vulkan-ドライバー)を参照)、共有フォルダー + SteamOS 内のマウントポイント + Steam ライブラリとしての使用 (`--share`、`--share-mount`、`--no-share`、`--share-library`、`--no-share-library`、[共有フォルダー](clipboard-and-shared-folder.md#共有フォルダー)を参照) |

**VM の RAM とグラフィックスは Mac のメモリを共有します。** VM の RAM を自動にした場合は物理 RAM の半分
(4–16 GiB) です。ランチャーは起動のたびに、macOS、他のアプリ、ドライバーのオーバーヘッド用に、少なくとも 3 GiB またはホスト RAM の 4 分の 1 を
確保します。残りが GPU の予算 (256 MiB–16 GiB、
256 MiB 単位で切り捨て) です。16 GiB の Mac では、VM 8 GiB + GPU 4 GiB + 予備 4 GiB になります。
VM をカスタムで 9 GiB にすると、グラフィックスには 3 GiB が残ります。Settings → Advanced には両方の割り当てが表示され、
カスタムの VM メモリでグラフィックスに残る量が 2 GiB 未満になる場合や合計を超える場合は警告が出ます。
KosmicKrisp と MoltenVK はどちらも、この予算を Venus の device-local ヒープと、
有効な場合は `VK_EXT_memory_budget` を通じて通知します。そのため zink の GL メモリクエリと DXVK/vkd3d には、
Mac のユニファイド RAM 全体ではなく、同じ小さなヒープが見えます (STEAMAC-S)。
`steamac.gpu_mib=` は Steam の VRAM 報告レイヤーも更新します。これはゲームのテクスチャ予算の目安になります。
厳密な割り当て上限ではなく、ゲームがこれを無視したり、他の
Mac アプリが予備を使い切ったりした場合、すべての OOM を防げるわけではありません。その場合は VM の RAM またはテクスチャ設定を下げてください。
使い捨ての VM でのチェックでは、`--cmdline '… steamac.gpu_mib=3072'` でホストとゲストの両方の報告を
上書きできます。`host/virglrenderer/test/memory_budget.c` はヒープ/予算を照会し、通知されたヒープまで実際の GPU
バッファを埋めます (予算の拡張機能を公開するには `VN_DEBUG=mem_budget` を付けて実行します。
Venus はデフォルトでこれを無効にしています)。割り当てテストを開発者のディスクで実行しないでください。

**ゲーム用の空き容量を増やす:** Mac の空き容量が自動的に SteamOS 内の空き容量になるわけではありません。
home の容量はディスク作成時に固定されます。**Settings → Advanced → Grow Disk…** で、
ディスクを作り直したりゲームを削除したりせずに容量を増やせます (拡大のみ、最大 4096 GiB)。実行中のディスクでは、
**Grow and Restart** が SteamOS を通常どおりシャットダウンし、VM の停止中にディスクの排他ロックを取得して、
イメージを拡大してから再び起動します。SteamOS は使用前に、最後の home パーティションを
`systemd-repart` で拡大し、続いてその ext4 ファイルシステムを `x-systemd.growfs` で拡大します。他のランチャーも
停止しておく必要があります。サスペンド中の VM もディスクを保持しています。APFS / Mac OS 拡張では、追加した領域は
SteamOS が書き込んだ分だけ消費されます。exFAT は追加した容量全体をすぐに割り当てるため、拡大の前に
空き容量をチェックします。SteamOS を停止した状態でターミナルから:
`work/out/steamac-vm --grow-disk /path/to/steamos.img --home-gib 128`。

**Mac の容量を取り戻す:** ゲームをアンインストールした後 (または大きく拡大した後)、スパースな
`steamos.img` は、SteamOS がそのブロックをもう必要としていなくても、ディスク上で大きいままのことがあります。
**Settings → Advanced → Reclaim Disk Space…** (SteamOS の実行中) は、ゲストに `/home` (マウントされていれば `/var` も) の `fstrim`
を依頼します。virtio-blk の DISCARD が Mac のイメージに穴を開けます。容量は
変わりません — 割り当てサイズが減るのは**イメージが APFS 上にある場合だけ**です。HFS+ と exFAT では
この方法で容量を取り戻せません。ランチャーは開始前にボリュームをチェックします。APFS のクローンやスナップショットが
解放されたブロックを保持することがあるため、Mac の空き容量が同じだけ増えるとは限りません。
これは GPT/home の縮小ではありません (そちらは拡大のみのままです)。

テスト用: `STEAMAC_DEFAULTS_DOMAIN=<domain>` は設定のドメインを置き換えます。`--selftest-settings
--selftest-out DIR` は VM なしでウィンドウを開き、各タブの PNG を書き出します。`--control-fifo` には
`settings TAB`、`settings-dump PNG`、`set KEY VALUE` (ウィンドウからの操作と同じ)、`restart` があります。

### ゲームごとのプロファイル

**Settings → Games** は、マウスの自動キャプチャとは別に、Steam の app id ごとにプロファイルを保存します:
**Graphics** — Default (= Vulkan) / Vulkan / DXMT、**Vulkan driver** — Default (グローバルのドライバー) /
KosmicKrisp / MoltenVK (利用可能なドライバーだけが表示されます)、**Launch options** — `%command%` の前に置かれる、
スペース区切りの `NAME=value` の語で、任意のシェルコマンドではありません。文字列全体は
256 文字までです。名前はプレフィックス `VKD3D_`、`DXVK_`、`PROTON_`、`WINE_`、`MESA_`、
`RADV_`、`VK_`、`DXMT_`、`MTL_`、`STEAMAC_` のいずれかに、0 文字以上の `[A-Z0-9_]` が続く形式です。
値は `[A-Za-z0-9_.,:;+-]*` に一致する必要があります (空も可)。代入は名前順に並べ替えられ、名前が重複した場合は
最後のものが優先されます。無効な入力はエラーとともに表示されたままになり、保存も送信もされません。空のフィールドは
プロファイルが何も上書きしないことを意味します (強制された値のように見えた `VKD3D_CONFIG=dxr` の例は、
フィールドに表示されなくなりました。STEAMAC-8X)。Metal Performance HUD に表示されるのは Mac の drawable のサイズで、
ゲームのレンダリング解像度とは異なる場合があります。

**Settings → Games** を開くだけでは、推奨プロファイルは取得されません。
**Get Recommendation** または **Retry** を押すと、**Share game statistics** の設定にかかわらず、
ゲームの Steam App ID と、この Mac の RAM 容量、GPU コア数、パフォーマンスコア数が統計サービスに送信されます。
サービスはこれらを **My Mac** の上限として使い、この Mac 以下の性能の Mac のプロファイルを探します。構成は
`(runs well + 0.5 × playable with issues) / all ratings` で順位付けされ、次に起動の成功率が高く、
早期終了が少ないものが優先されます。少なくとも 2 つの異なるインストールが必要です (詳細は[ゲーム統計](privacy-and-updates.md#ゲーム統計)を参照)。
該当するプロファイルは **Recommended: … — Apply** と表示され、**Apply** を押したときだけ適用されます。

DXMT には **Settings → Advanced → Allow DXMT (D3D11 on the Mac's Metal)** と、その許可を付けた
VM の起動が必要です。オフの間、DXMT のプロファイルは無効として表示され、既存のセキュリティ警告とともに
**Allow DXMT…** が表示されます。Vulkan のみで起動した VM では、DXMT の互換ツールを選択できません。
Vulkan ドライバーはプロセスごとではなく、**VM の起動ごと**に選択されます。別のプロファイルドライバーを持つゲームが
起動したりフォーカスを得たりすると、ランチャーはそのドライバーで VM を再起動し、Steam の準備ができたら
ゲームを再起動することを提案します。この 1 回限りの上書きは、グローバルのドライバー設定を変更しません。

プロファイルは双方向の `fx.progress` ポートで送られます (1 メッセージにつき 1 行)。ホスト → ゲスト:
`profiles <base64 of UTF-8 JSON>` は、起動後の最初のエージェントの heartbeat/ready 時と
変更後に、全体を置き換えます。`launch <appid>` はセッションユーザーとして `steam steam://rungameid/<appid>` を起動します。
`restart-steam` は、ユーザーが同意した場合にのみ `steam.service` を再起動します。プロファイルのペイロードは
`{"v":1,"games":{"570":{"gfx":"dxmt","env":"PROTON_LOG=1"}}}` です。デフォルト/空のフィールドは省略され、
`driver` はホスト側にとどまります。ゲストはこれを
`~/.config/steamac/game-profiles.json` にアトミックに保存します。グラフィックス/タイトルの準備の前に、`steam-profiles-wait`
の ExecStartPre がこの起動の同期を最大 5 秒待ち、その後、利用可能な最新の
セットのスナップショットを取ります (タイムアウト時は保存済みのファイルを使います)。ゲスト → ホスト: `profiles-ok <sha256 of JSON> applied|pending`。
`pending` は、Steam が別の適用済みセットで実行中であることを意味し、ランチャーは **Restart Steam**
または **Later** を提案します。`game-gfx <appid> dxmt|vulkan` は `game-proton` の後に続き、実際の Proton の
グラフィックスパスを示します。これは起動時の許可ではなく、`.steamac-dxmt` マーカーから検出されます。
未知の動詞は引き続き無視されるため、新旧のホスト/ゲストの組み合わせでも動作します。

Steam の起動時、プロファイルの起動用の語は `steam-title-defaults` の組み込みエントリーを上書きします。プロファイルに
`env` がない場合、Dragon's Dogma 2 は Venus の機能に依存するデフォルトを維持します。所有権は変わりません:
後から Steam でユーザーが編集したものが優先されます。steamac が管理する語を置き換えたり削除したりしても
古い代入が積み重なることはなく、削除すると以前の起動オプションに戻ります。
