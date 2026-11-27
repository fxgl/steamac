# ソースからのビルド

[English](../building.md) · [Русский](../ru/building.md) · [简体中文](../zh/building.md) · **日本語**

← [マニュアル](README.md)

## 必要なもの

- Apple Silicon Mac、macOS 15 以降、約 150 GB の空き容量 (ディスクイメージはスパースファイルです)。
  ランチャーには Mac 本体の Hypervisor.framework が必要です: macOS の仮想マシン内 (Paravirtual GPU、
  `kern.hv_vmm_present`) や `kern.hv_support` がない環境では、その旨を説明して VM の起動前に終了します。
  libkrun の `krun_start_enter failed: -22` を報告することはありません (STEAMAC-15)。
- Xcode 26 以降 (フルインストール: その `actool` が Icon Composer のドキュメントからアプリアイコンをビルドします)、Homebrew、rustup。
- KosmicKrisp (任意、代替の Vulkan ドライバー): macOS 26 以降でのみビルドされます。`host/kosmickrisp/build.sh`
  が Homebrew の依存関係 (`llvm spirv-llvm-translator spirv-tools vulkan-loader glslang`) をインストールします。
- OrbStack (または arm64 と `--privileged` に対応した Docker): カーネル、Mesa、ディスクイメージは Linux コンテナ内でビルドされます。
- Homebrew パッケージ: `meson ninja pkg-config dtc xz lld sshpass go` (`go`: 同梱の gvproxy/desync のライセンス一覧用)。
- libepoxy 1.5.10 は、virglrenderer と libkrun より前に、`host/libepoxy/build.sh` によって固定されたソースからビルドされます。
  3 つとも `MACOSX_DEPLOYMENT_TARGET=15.0` を使います。macOS 26/27 のビルドホストでも同様です。
  バンドル時には、デプロイメントターゲットが macOS 15.0 を超える Mach-O は拒否されます (KosmicKrisp だけは 26.0 を要求できます)。

## ビルドと実行

```sh
./build.sh          # Vulkan stack: MoltenVK, virglrenderer, libkrun, launcher, kernel, Mesa, disk
./build.sh dxmt     # DXMT + wmtr host executor and guest payload; then rebuild layer and launcher (below)
./run.sh            # a window with SteamOS
```

部分ごとにビルドするには: `./build.sh host`、`./build.sh guest`、または下の表のスクリプトを使います。
SteamOS イメージは Valve のサーバーからダウンロードされ (署名済みの RAUC バンドル)、その署名と
sha256 が検証されます。

ゲストのリリース成果物には、隣に `.inputs.json` というビルドレシートがあり、選択された Git の
作業ツリーの入力と出力バイトを結び付けています。関係する未コミットの編集があると無効になりますが、無関係なコミットでは
無効になりません。`host/launcher/bundle.sh` は、アプリを変更する前に、欠落した/古いレシートを拒否します。
`dist.sh` も、パッケージングの前に、既存のアプリ内のレシートとリソースを検証します。
エラーには再実行すべき手順が示されます。既存の SteamOS ディスクに触れずにゲストの成果物を更新するには:
`guest/kernel/build.sh` (入力が変わった場合か、レシートがない場合のみ)、
`scripts/build-image.sh builder rootfs`、`guest/mesa/build.sh`、次に
`scripts/build-image.sh initramfs layer`、最後に `host/launcher/build.sh` を実行します。スタンプのない成果物は
通常のビルドを一度行う必要があります。カーネルのビルドは `clean` なしでビルドボリュームを再利用します。
`ALLOW_NO_VENUS=1` のレイヤーはテスト専用で、リリースできません。

VM のオプション: `./run.sh --display 1920x1080 --cpus 10 --mem 24576` (全一覧:
`work/out/steamac-vm --help`)。

フレームペーシング: `./run.sh --perf-stats` (または `STEAMAC_PERF_STATS=1`) は、ゲストのフレームと画面上の
フレームの間隔を 5 秒ごとにターミナルに出力します (p50/p95/p99/max、25 ms 超と 50 ms 超の間隔の数)。
新しいエフェクトが初めて表示されるときのカクつきは、Metal のシェーダーコンパイル (パイプラインあたり約 50–100 ms)
によるものです。Metal は結果をディスクにキャッシュするため、そのエフェクトで再びカクつくことはありません。ゲームや VM を
再起動した後も同様です (Venus 経由での測定: 新しいプロセスでパイプラインあたり 102 ms → 0.95 ms)。

Steam の Shader Pre-Caching と “Allow background processing of Vulkan shaders” (Settings → Downloads) は、
VM ではデフォルトでオンです。Proton にトランスコード済みのカットシーン動画をもたらすのは事前キャッシュです: Steam は
ゲームごとにそれらをダウンロードし (`steamapps/shadercache/<appid>/transcoded_video.foz`。たとえば
Heroes of Might and Magic: Olden Era では 836 MB、Diplomacy is Not an Option では 3.8 GB)、
`STEAM_COMPAT_TRANSCODED_MEDIA_PATH` を Proton に渡します。Proton は自身でデコードできない動画にそれらを再生します。
事前キャッシュをオフにすると、それらの動画にはプレースホルダーが表示されます。DXVK 自身のキャッシュ (DXVK 2.7) はゲームの
Wine プレフィックスにあり、どちらの場合も機能します。代償として、Steam の fossilize_replay が処理するすべてのパイプラインが
Mac 上の Metal でコンパイルされます (約 70–100 ms)。また Steam は、あるゲームのシェーダー更新の後と、
MoltenVK を変更するランチャーの更新の後にはすべてのゲームについて、再び処理を行います (Venus ドライバーの ID は
MoltenVK の `pipelineCacheUUID` のハッシュです)。バックグラウンド処理によって、その大部分は Steam が
アイドルの間に行われます。残りはゲームの起動時に “Processing Vulkan shaders” として表示され、**Skip**
でスキップできます。オフにするには: Steam → Settings → Downloads → Enable Shader Pre-caching (および/または Allow
background processing of Vulkan shaders)。

標準の Steam ではバックグラウンド処理はオフです (`~/.local/share/Steam/config/config.vdf` に
`EnableShaderBackgroundProcessing` がない場合は 0 として扱われます)。Steam の起動前に、
`/usr/lib/steamac/steam-shader-defaults` (`steam.service` の ExecStartPre) が、まだ値がなければ
`"EnableShaderBackgroundProcessing" "1"` を `ShaderCacheManager` ブロックに書き込みます。
これは Steam のインストールごとに 1 回だけ行われるため (マーカー `config/steamac-shader-defaults`)、Steam の
設定で行った選択は維持されます。ランチャー 1.4 は両方の設定をオフで出荷していました (`"DisableShaderCache" "1"`、
`"EnableShaderBackgroundProcessing" "0"`)。更新後の最初の Steam 起動時に、このスクリプトは
両方を 1 回だけオンに戻しますが、それは両方がまだ正確にその値である場合に限ります。

ゲームモードでは、Steam UI を従来の 1920 × 1080 上限ではなく、仮想ディスプレイのネイティブ解像度で
表示します (Retina を含む)。解像度はランチャーの仮想ディスプレイのサイズ上限に従います。
新規インストールでは、初回サインイン後の Steam 起動時に設定され、新しい gamescope セッション
(VM の再起動など) で有効になります。Steam の再起動だけでは既存の UI 上限は解除されません。

ゲームのグローバル解像度が未設定または `Default` の場合は、従来の上限 (1920 × 1080、16:10 では
1920 × 1200。小さいディスプレイでは優先モード) が使われます。ランチャーが書き込んだ値のままであれば、
Steam の起動時にだけ現在の仮想ディスプレイに合わせて再計算します。ウィンドウのサイズ変更や
フルスクリーンへの切り替えだけでは上限は変わりません。明示的な設定 (`Native` を含む) やゲームごとの
上書きは維持されます。ネイティブ UI が有効な状態で別のアカウントに初めてサインインすると、
次回の Steam 起動までは `Default` のゲームがネイティブ解像度で動作することがあります。

Steam のアイドル時スクリーンセーバー (Settings → Display → Screensaver in Game Mode) は VM ではオフです。
入力のない状態が数分続くと、Steam は実行中のゲームの前面に `Screensaver_uid<n>` ウィンドウを表示し、
gamescope がそこにフォーカスを移すため、Escape を押すまで次のクリックは Steam に届いてしまいます。ランチャーのマウス、
タブレット、キーボードは Steam のタイマーをリセットしますが、長いロード画面のまま放置されたゲームや、
VR でプレイ中のゲーム (ヘッドセットの入力は Steam に届きません) は、Steam からはアイドルに見えます。macOS 自身のスクリーンセーバーとディスプレイの
スリープはそのまま維持されます。Steam の起動前に、`/usr/lib/steamac/steam-idle-screensaver` (`steam.service` の
ExecStartPre) が `"IdleScreensaverACSeconds" "0"` と `"IdleScreensaverBatterySeconds" "0"`
(`config.vdf` の `InstallConfigStore/Software/Valve/Steam/System`。0 = なし) を、それらが
ない場合に書き込みます。これは Steam のインストールごとに 1 回だけ行われるため (マーカー `config/steamac-idle-screensaver`)、
後で Steam の設定で選んだスクリーンセーバーのタイムアウトは維持されます。

ゲームが動作するドライバーに対して必要とするタイトルごとの環境は、コードではなくデフォルト値として扱います:
`/usr/lib/steamac/steam-title-defaults` (これも `steam.service` の ExecStartPre) が、必要な
`VAR=value` の語をタイトルの Steam 起動オプション (`%command%`) の前に付け加えます。出荷時のエントリーは 1 つです:
Dragon's Dogma 2 (2054970) は D3D の機能レベル 12_1 を要求します。vkd3d-proton はこれを ROV と
コンサバティブラスタライゼーションから導き出しますが、Metal にはどちらもありません (コンサバティブラスタライゼーションには Metal の API がなく、
ROV には Metal の raster order groups を `VK_EXT_fragment_shader_interlock` に対応付ける必要があります)。また、この
タイトルはレベルを確認するだけなので、`VKD3D_FEATURE_LEVEL=12_1 VKD3D_SHADER_MODEL=6_6` として報告されます。
あわせて `VKD3D_DISABLE_EXTENSIONS=` (空) も設定されます。KosmicKrisp の 64 ビットアトミックは符号なしの
min/max しか対応していないため、`steam.service` はデフォルトですべての D3D12 タイトルから `VK_KHR_shader_atomic_int64` と
`VK_EXT_shader_image_atomic_int64` を外します
(ドロップインの `Environment=VKD3D_DISABLE_EXTENSIONS=…`。シェーダーが別の 64 ビット
アトミックを使うタイトルは、それらのパイプラインを黙って失うことになり、vkd3d-proton はそれらからシェーダーモデル 6.6 を報告します)。
条件に合うタイトルは、自身の起動オプションでそれらを取り戻します。このデフォルトは Steam から継承された
環境であって、`gfx.txt` の行ではありません: `steam-launch-wrapper` は
`$XDG_RUNTIME_DIR/steam/env/gfx.txt` と、その次に `~/.config/steam/env/gfx.txt` のすべての変数を、起動オプションを含むゲームの
環境の上に設定します。そのため、そこに書かれた `VKD3D_DISABLE_EXTENSIONS` はすべての
タイトルで優先されます。エントリーは、Venus デバイスが必要な機能を提供している場合 (DD2 の場合:
64 ビットアトミック、Apple8/M2 以降) にのみ適用され、以降の Steam 起動時にその機能がなくなっていれば
(ドライバーを MoltenVK に切り替えた、ディスクを M1 に移した)、以前の起動オプションに戻して取り消されます。プローブが失敗した場合は
何も変更しません。既存の値には前に付け加えるだけで、置き換えることはありません。`%command%` を含まない値は
そのままにし、私たちの後に Steam で行った編集が優先されます (マーカー
`~/.config/steamac/title-defaults.json`。以前の値もここに保持されます)。
プロファイルの `env` の語は組み込みのエントリーより優先されます。プロファイルでの上書きがなければ、DD2 は機能に応じたデフォルトを維持します。

SteamOS は Mac のタイムゾーンと 12/24 時間の時刻形式を引き継ぎます (Settings > General
**Use the Mac's time zone and clock format**。デフォルトでオンで、次回の起動時に適用されます)。
起動のたびに、ランチャーは `steamac.tz=<IANA zone of the Mac>` (`TimeZone.current`) と
`steamac.clock24=0|1` (ローカライズされた `j` の時刻テンプレートで、macOS の **24-hour time** スイッチに従います) を追加します。
initramfs は `/etc/localtime` をそのゾーンに向けます (`timedatectl`、`steamos-set-timezone` による Steam の Time zone 設定、
および Steam の時計)。`/etc/steamac/mac-timezone` は最後に適用した
ゾーンを記憶します。SteamOS 内で別のゾーンを選んだ場合は、それが維持されます (再び Mac のゾーンと同じになるまで)。
Steam の起動前に、`/usr/lib/steamac/mac-clock-format` が、アカウントの
`userdata/<account>/config/localconfig.vdf` 内の
`UserLocalConfigStore/Software/Valve/Steam/FriendsUI/FriendsUIJSON` にある `b24HourClock` を更新します。これは Steam の
Settings → Time and date → 24-hour clock のトグルであり、クライアント全体の設定ではありません: 新しいディスクでは、このファイルは
サインイン前には存在しないため、**サインイン後**の最初の Steam 起動時に適用されます。
デスクトップモードでは `~/.config/plasma-localerc` に `[Formats] LC_TIME` が設定されます (24 時間制では `en_GB.UTF-8`、
12 時間制では `en_US.UTF-8`。これにより時刻/日付のロケールも選択されます)。最後に適用した値と
ユーザーによる個別の上書きは `~/.config/steamac/mac-clock24.json` に保持されます: Steam や Plasma で形式を
変更すると、その設定については Mac への追従を止め、もう一方は変更しません。
ランチャーの設定がオフの場合、ゾーンも形式も変更されません。テストでは、macOS の設定を変えずに
`--cmdline "console=hvc0 rootwait steamac.clock24=0"` (または `1`) を明示的に指定できます。

起動とシャットダウンの進行状況は `ready` になるまで消えません: ウィンドウ内での最初のクリックかキー入力で、
全画面のオーバーレイが下部中央の進行状況ピルに折りたたまれます (段階、
パーセント、バー、`378 / 564 MB · 1.9 MB/s` のような詳細行。入力はゲストに届きます)。ピルを
クリックするか View → Show Boot Progress を選ぶと、再び展開されます。オーバーレイを無効にしている場合 (Settings >
General)、ピルがすぐに表示されます。新しいディスクの準備中や Steam クライアントの
ダウンロード / インストール中は、クリックやキー入力ではオーバーレイは折りたたまれず、以前に
クリックで折りたたまれたオーバーレイは自動的に展開されます (`overlay: expanded for
steam-download`)。View → Show Boot Progress で折りたたんだものは、`ready` までピルのままです。
`ready` の前は、ウィンドウのタイトルに段階が表示されます: “FX Steam Launcher — Downloading Steam update 70%”、
“— Starting Steam…”、“— Shutting down…”。ログには `overlay: collapsed to pill (click)` /
`expanded from pill` が記録されます。`ready` の後、ウィンドウに 3 秒以上画像がない場合 (スキャンアウトがオフ、または
スキャンアウトの設定やサイズ変更の後にフレームが届いていない)、または表示中のフレームが
5 秒以上黒い場合 (64 × 40 点の疎なサンプリングで、99.5% 以上の点の明るさが 8/255 未満。チェックは 1 秒に最大 4 回、
約 3 µs)、かつフォーカスがゲームになく、ゲストがスリープ / 一時停止 / サスペンド中でもない場合、
ピルには “Waiting for SteamOS to draw…” と、その理由、エージェントのハートビート、VM の CPU 使用率が表示されます。
最初の黒くないフレームで消えます (`no-picture: shown after 5.0 s (black picture …)` /
`hidden after … (first non-black frame)`)。テスト:
`work/out/steamac-vm --selftest-pill --selftest-out DIR`。

ゲームにフォーカスがある間 (`focus game <appid>`)、ゲストが 2 秒間 GPU コマンドを送らない場合 (
virtio-gpu の制御キューと Venus のリング — `krun_gpu_get_activity` のカウンター)、最後のフレームの上に “Still
working — loading or compiling shaders…” というカードが VM の CPU 使用率とともに表示されます。
ゲストエージェントがハートビートの送信も止めている場合 (5 秒超) は、“SteamOS is not responding…” と表示されます
(これはフォーカスに関係なく適用されます)。アイドル状態の Steam のインターフェースは何分も GPU コマンドを送らず、
インジケーターはトリガーされません。インジケーターは次の GPU コマンドで、またはフォーカスがゲームから
離れたときに消えます。発生のたびにログに記録されます (`stall: gpu idle 3.1 s (guest alive, …)`)。`--perf-stats` を指定すると、
`perf: gpu ctrl/s=… ring/s=… longest-idle=…` という行が 5 秒ごとに追加されます。Settings > General で無効にできます。エージェントは各
gamescope セッション (ゲームモードとデスクトップモード) で動作します: セッションが終了すると (Switch to Desktop、Return to Gaming
Mode)、新しいセッションのエージェントが送信するまでハートビートは期待されません。VM のサスペンド中や
スリープ中はインジケーターはオフで、レジューム、ゲストのウェイク、Mac のスリープの後は、アイドルとハートビートのタイマーが
最初からやり直しになります。各チェックは GPU のアイドル時間とハートビートの経過時間を同じ瞬間に測定するため、Mac
自身が遅らせたチェック (ページング、ビジー状態のメインスレッド) でハートビートだけが古くなって “not responding” になることはありません
(STEAMAC-8)。Reclaim Disk Space の確認、エラー、結果のダイアログは、シートまたは別ウィンドウであり、SteamOS の実行中に
メインキュー (ハートビートを配送します) を止めるモーダルループではありません。

| ウィンドウ内のキー | |
|---|---|
| Ctrl+Cmd+F | フルスクリーン (macOS がゲームモードをオンにします: Info.plist がゲームであることを宣言しています — `LSApplicationCategoryType` `public.app-category.games`、`GCSupportsGameMode`、`LSSupportsGameMode`。`gamepolicyd` は “Game mode status is now on” と記録します) |
| Ctrl+Cmd+G | 手動でマウスをキャプチャ / 解放 |
| Ctrl+Cmd+P | Apple の Metal Performance HUD (FPS、フレーム間隔、GPU 時間、メモリ) の切り替え。View → Show Metal Performance HUD と Settings > Display からも操作できます。HUD のライブラリは、VM の起動時に HUD がオンの場合にのみ読み込まれます: オンにすると再起動後に有効になり、オフにするとすぐに非表示になって次回の再起動時にアンロードされます。Apple の HUD は、macOS 26 上の KosmicKrisp (Metal 4) で、オーバーレイを非表示にしていても VM をクラッシュさせたことがあるため (STEAMAC-59/7K/7Q/9X/9Y)、KosmicKrisp でオンにする際は確認を求めます。Apple の HUD を使わない代替として、Settings > General > Log frame-pacing statistics でゲストのディスプレイのタイミング (ゲームの FPS ではありません) を記録できます。クラッシュレポートには、要求された HUD の状態と実際の状態、ライブラリが注入されたかどうか、ドライバーが含まれます |
| Ctrl+Option | キャプチャしたマウスを解放 |
| ウィンドウを閉じる | ゲストをシャットダウン (電源ボタン) |

マウス (`--mouse auto`、デフォルト): SteamOS のカーソルは Mac のカーソルに正確に追従し、Mac の
カーソルは画像の上では非表示になるため、gamescope のカーソルだけが表示されます (黒い帯、
クリック可能な進行状況ピルと "Report…" リンク、メニューや他のウィンドウの上、起動中、一時停止中、
スリープ中、ウィンドウの外では再び表示されます)。gamescope
(ゲームモード) は絶対座標を受け付けないため、ランチャーは加速なしの相対的な移動量で、
gamescope が表示するサーフェスのピクセル単位でカーソルを動かします: エージェントは各フォーカス行でそのサイズを送ります
(Steam の Settings > Display > Resolution がネイティブ以外の場合は `focus steam 1920x1200`。この場合 UI はディスプレイより小さく、
拡大して表示されます)。ランチャーは、gamescope がそのサーフェスをディスプレイに拡大するのと同じように、ウィンドウをその
サーフェスに対応付けます (`--selftest-pointer`)。ゲスト内でゲームにフォーカスがあるとき
(エージェントが `focus game <appid> <w>x<h>` を送ります)、
最初のクリックでマウスがキャプチャされます (マウスルック用の相対移動)。Ctrl+Option で解放されます。
Steam に戻ると、キャプチャは自動的に解放されます。**Mouse** メニュー:
- **Capture Mouse in This Game** — 現在のゲームで自動キャプチャ (appid ごとに保存);
- **Auto-Capture Mouse in Games** — すべてのゲームのデフォルト;
- **Capture / Release Mouse Now** — Ctrl+Cmd+G と同じ。

これらを含むすべての設定は [**Settings** ウィンドウ](settings.md#設定ウィンドウ) にあり、ドメインは
`es.fxgam.steamac` です (`defaults read es.fxgam.steamac`)。初回起動時に、以前のドメイン
`dev.steamac.vm` から 1 回だけコピーされます。Metal はシェーダーキャッシュをアプリの識別子ごとに保存するため、
識別子を変更した後の最初のゲーム起動ではシェーダーが再びコンパイルされます (1 回の「コールド」スタート)。
`--auto-capture on|off` で、1 回の起動に限りデフォルトを上書きできます。
`--mouse tablet` — 絶対座標のタブレット (gamescope は無視するため、他のゲストのコンポジター専用)、
`--mouse capture` — クリック時に常にキャプチャ。

ゲストへのアクセス: `ssh -p 2222 steamos@127.0.0.1`、パスワードは `steamos` です (変更するには
`STEAMOS_PASSWORD=... scripts/build-image.sh disk`)。hvc0 コンソールは、`run.sh` を実行している
ターミナルにあります。

SSH は 1 つのスイッチで切り替えます: **Settings → Advanced → Enable SSH** (または `--ssh-port N` /
`--no-ssh`)。起動のたびに、ランチャーは `steamac.ssh=0|1` を渡します: 0 の場合、Mac のポートは
まったく開かれず (転送なしの gvproxy)、initramfs が SteamOS 内の sshd をマスクします。デフォルトでは、SSH は
開発用ランチャー (`work/out/steamac-vm`、`./run.sh`、ポート 2222) では有効で、
`FX Steam Launcher.app` では無効です (Info.plist の `SteamacReleaseDefaults` キーで、`bundle.sh` が設定します)。
有効にすると、ランチャーはユーザー `steamos` のパスワードを生成し (20 文字、SecRandomCopyBytes)、
ディスクごとに (その GPT GUID によって) キーチェーンに保存し、次回の起動時には
その SHA-512 crypt ハッシュだけをゲストに渡します (“config payload” ディスク、`steamac.config=1`。ゲストは
`config applied` と応答します)。Settings には、ユーザー、パスワード (Show/Copy)、すぐに使えるコマンド
`ssh -p … steamos@127.0.0.1`、状態 “applied / will apply on next start”、**Regenerate Password** が表示されます。
開発用ランチャーでは、パスワードはボタンからのみ生成されます (Docker でビルドしたディスクは
`steamos` のままです)。アプリで作成したディスクは、この方法でのみパスワードを受け取ります — デフォルトの
パスワードはありません。ターミナルからは、`steamac-vm --ssh-password <disk>` でユーザー、パスワード、
状態を表示できます。

## Docker を使わない SteamOS ディスクの作成

アプリのユーザーは Docker を必要としません: ランチャー自身がディスクを作成します — 初回起動
ウィンドウの **Create New Disk…** または **Settings → Advanced → Create New Disk…** から作成できます (stable/rc
ブランチ、home のサイズ、場所、ユーザー `steamos` のパスワード。進捗、Stop、Resume)。提示されるのは stable
と rc のみです: beta/preview/main は Valve の開発用署名鍵を使っている場合があり、それはランチャーに
信頼されていません。保存済みのサポートされないブランチは stable にフォールバックし、ログに記録されます。同じことを
ウィンドウなしで行うには:

```sh
work/out/steamac-vm --create-disk ~/steamos.img [--branch stable] [--home-gib 64] [--password PW] [--keep-cache] [--accept-eula]
```

ユーザーが Valve の規約に同意するまでは何もダウンロードされません: 「End User License Agreement for
SteamOS and Steam Client Back-Up Image」(Steam Frame のイメージページと同じテキスト、
`https://store.steampowered.com/steamos/download/?ver=steamframe`: 個人利用のみ、
再配布不可) と Steam 利用規約です。ウィンドウではこれは両方のテキストへのリンク付きのチェックボックスで
— チェックしないと Create は使えません。コマンドラインでは `--accept-eula` で、
これがないと `--create-disk` はリンクを表示してコード 2 で終了します。同意 (日付と
規約の URL) は設定ドメインに保存され、コード内の規約 URL
(`SteamOSLicense.eulaURL`) が変わるまで有効です。

外部の APFS、Mac OS 拡張、exFAT ボリュームにディスクを置くことができます。APFS を推奨します。FAT32/MS-DOS は
ファイルごとに 4 GiB の制限があるためダウンロード前に拒否されます (一時的な rootfs だけで 10 GiB あります)。また
NTFS、ネットワークファイルシステム、不明なファイルシステムドライバーも拒否されます (STEAMAC-8S: NTFS ドライバーが 1 時間のダウンロード後に
92 GB のディスクを「File too large」で拒否しました)。後からのファイルサイズによる拒否は説明され、
ログに記録されますが、Sentry には送信されません。
読み取り専用のボリュームや書き込みできないフォルダーも拒否されます。APFS と異なり、exFAT にはスパースファイルがありません: ゲームをインストールする前から、
選択したディスクサイズ全体と一時的な rootfs の分の空き容量が必要です。そこではダウンロードキャッシュも、データ量の約 4.4 GB を
はるかに超える容量を使います: macOS は各チャンクファイルの provenance 属性を追加の `._` ファイルに保持し、すべてのファイルと
フォルダーがクラスター単位 (2 TB のドライブでは 128 KiB) で領域を占めるため、合計で約 28 GB になります。ランチャーは
rootfs を再構築する前にこの容量をチェックし、exFAT ではそうしないとボリュームが満杯になる場合に、ディスクを割り当てる前に
チャンクキャッシュを削除します (`--keep-cache` はキャッシュを残し、両方の分の空き容量が必要です)。
想定される場所の失敗 (既存の保存先、使用中のキャッシュ、読み取り専用のボリューム、書き込み権限がない、
ボリュームが満杯、ドライブの切断、作成中に消えた保存先やキャッシュフォルダー、または
ファイルシステムの I/O エラー) は、作成開始後の失敗も含めて、案内付きでログに記録され、Sentry にエラーとして
送信されることはありません。メタデータ/バンドルの接続失敗 (オフライン、DNS、タイムアウト、
接続の切断、システムによる TLS の拒否) は、desync のダウンロード再試行が尽きた場合と同じ方針に従います。
これにはチャンクの HTTP レスポンスボディ読み取り中のタイムアウト (STEAMAC-92) も含まれ、メタデータのレスポンス
が JSON でない場合 (空、途中で切れている、HTML のポータルやプロキシのページ) や HTTP による拒否も同様で、その HTTP
ステータス、Content-Type、長さ、先頭 160 バイトとともにログに記録されます (STEAMAC-AQ: `stable.json` からの `NSCocoaErrorDomain 3840`。
互換性のないスキーマを持つ有効な JSON は引き続き報告されます)。desync が
チャンクをキャッシュに保存できない場合 (exFAT のキャッシュでの `invalid argument`、STEAMAC-90/91)、ログには診断のために、失敗した
キャッシュシャードの状態 (モード、エントリー数と一時ファイル数、読み取りエラー) が記録されます。
HTTPS の証明書検証が回避されることはありません。想定外の作成失敗とバンドル署名の失敗は、引き続き
元の技術的な診断情報をイベントの詳細に含めて報告されます。同梱の desync が存在しない、読み取れない、または
実行できない場合 (STEAMAC-8K)、ウィンドウはインストールが不完全であることを説明します: 公式の
DMG から Applications に再インストールし、セキュリティソフトウェアを確認してください。インストールごとに 1 回の警告で、
トランスロケーション、desync の有無と権限、コード署名の結果、バンドルを基準とした
Resources の名前とサイズが記録されます。バンドルの絶対パスはローカルのログにとどまり、クラッシュレポートのダイアログは開きません。
この警告には、バンドル、`Contents`、`Resources` がまだ存在するかどうか (種類と errno) も記録されます: 実行中に
移動、削除、置き換えられたアプリは 3 つすべてを失うため (STEAMAC-AE)、案内では、置き換えや移動の前に
FX Steam Launcher を完全に終了し、その後 Applications から再度開くよう求めます。
ランチャーは保存先/キャッシュのファイルシステムの種類をログに記録します。チャンクキャッシュのリネームの衝突は、
1 つのワーカーでキャッシュなしで 1 回再試行されます。rootfs のハッシュの不一致は、順次読み取りで再度チェックされ、不正な
スパースエクステントのメタデータと不正なファイルのバイトを区別します。バイトが不正な場合は、一時的な rootfs とチャンクキャッシュを
削除し、キャッシュなしで順次に 1 回だけ再ダウンロードします。再試行の前に両方のディスクスロットがクリアされます。
2 回目の整合性の失敗は報告対象のままです。署名されたマニフェストと一致しないディスクが公開されることはありません。
順次読み取りの SHA-256 と、ソースの再読み取りが rootfs-A と異なる最初の 1 MiB ブロック
(オフセットと両方のブロックのダイジェスト) が記録されるため、不安定な読み取りとコピーのエラーを区別できます (STEAMAC-9F/9H)。
ディスク作成では、読み戻したパーティションテーブルと書き込んだ内容を、プライベートファイル内と
ディスクの公開後の両方で比較します。差異がある場合 (STEAMAC-6J、exFAT)、またはディスクの割り当て前に
再構築した rootfs が消えた場合 (STEAMAC-68) は、ファイルの識別情報と異なる GPT
フィールドとともに報告対象のままとなり、ウィンドウはディスクユーティリティの First Aid か別のドライブを提案します。

ダウンロードが Valve に安全に到達できない場合、ウィンドウは VPN、プロキシ、またはネットワークフィルターが
干渉している可能性を説明します: それを無効にするか、別のネットワークを使ってみてください。アップデートチェックでも
GitHub について同じ助言が表示されます。技術的な詳細はランチャーのログにとどまります。HTTPS は macOS 標準の証明書
検証と TLS 設定を使います。以下の固定された Valve の CA はダウンロードしたバンドルを検証するもので、HTTPS を検証するものではありません。

`rc` は引き続き利用できますが、Valve は最新のビルドを本番の CA ではなく開発用の鍵
`steamos-dev-images` で署名することがあります。そのビルドは受け入れられません: ランチャーは
この開発用の署名を検証できないことを説明し、`stable` を選ぶか後でもう一度試すよう求めます。
この想定された拒否はログに記録されるだけです。その他のすべての署名の失敗は引き続き Sentry に報告されます。

1. `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<branch>.json` → 最新の
   候補 (`update_path`、`chunks_store_path`)。
2. `.raucb` (約 2 MB) がダウンロードされます。Security.framework はその CMS 署名を、Valve の固定された CA
   `CN=steamdeck-images` (`scripts/keys/steamdeck-images.pem`、SHA-256 フィンガープリントは
   コードに埋め込み) に対してのみ検証し、システムのトラストストアは使いません。独自の squashfs リーダー (固定された zstd リリースの zstd を
   使用、`fetch-zstd.sh`) が `manifest.raucm` と `rootfs.img.caibx` を取り出し、
   `compatible=steamos-aarch64`、バージョン、スロットサイズがチェックされます。
3. 公式の desync (`fetch-desync.sh`、固定されたバージョンと sha256) が、Valve のチャンクストア (データ量は約 4.4 GB) から
   10 GB の `rootfs.img` を組み立てます。チャンクキャッシュは、ホームボリューム上のディスクでは
   `~/Library/Caches/es.fxgam.steamac` 内の `desync/`、それ以外ではディスクの隣の `<disk>.cache` です
   (これにより外部ドライブでは内蔵ストレージの空き容量は不要です。フォルダーは成功後に
   削除されます)。そのため Stop/Resume (または Ctrl+C の後のコマンド再実行) で中断したところから再開できます。後で失敗した試行で
   残った完全な `<disk>.rootfs-tmp` は最初に削除されます (desync はこれを再利用することはなく、
   容量を二重に使ってしまうためです)。キャッシュごとに作成は一度に 1 つだけです: 2 つ目 (別の
   ウィンドウや `--create-disk`) は、チャンクキャッシュと一時ファイルを共有する代わりに「another SteamOS disk is being created」
   と表示して停止します (キャッシュフォルダー内の `creation.lock` に対する `flock`)。
4. スパースディスクファイル: `scripts/steps/40-disk.sh` とまったく同じ名前、順序、種類、サイズ、アライメントを持つ
   保護 MBR + GPT (プライマリとバックアップ、CRC32) と、ランダムな PARTUUID。1 回の
   パスで `rootfs.img` のハッシュを計算し (sha256 は署名されたマニフェストと一致する必要があります)、16
   KiB のゼロでないブロックを rootfs-A と rootfs-B に書き込みます。その他のパーティションはゼロです。ディスクは
   すべてのチェックの後にのみ最終的な名前で現れます。既存のファイルは上書きされません。アトミックな排他的リネームが
   ない exFAT では、ランチャーは作成ロックを保持したまま保存先をチェックし、
   その後リネームします。作成中に、ランチャー以外のプログラムで同じ保存先に別のファイルを作成したり移動したり
   しないでください: そのチェックとリネームは、それに対してはアトミックではありません。
5. `<disk without .img>.provision.img` がその隣に置かれます — cpio newc 形式で、
   `provision.env` (ビルド、PARTUUID、SHA-512 crypt のパスワードハッシュ、machine-id) と `rootfs.caibx`
   (形式: プロビジョニング契約の「Payload v1」) を含みます。このファイルが存在する間、ランチャーは
   これを読み取り専用 (vdc) で接続し、`steamac.provision=1` を追加します: initramfs は
   esp/efi-X/var-X/home をフォーマットし、rootfs-B の fsid を一意にし、partsets/bootconf/bootenv/var を書き込み、
   `provision done` を報告します — ランチャーはその後ペイロードを削除し、以降の起動では
   それを使いません。

スパース対応のボリュームでの必要容量: 作成中はディスクのボリュームに約 20 GB (作成後は約 9 GB)、さらにキャッシュに約 6 GB。
desync は macOS 上では APFS でも 10 GiB の一時的な rootfs 全体を事前に割り当てます。スパースのままなのは 2 つの保存先スロットだけです。
事前チェックの見積もりにはこの割り当てと安全マージンが含まれます (SteamOS 20261007 では合計約 27 GB)。
`--keep-cache` が指定されていない限り、キャッシュは成功後に削除されます。
チェック: `work/out/steamac-vm --selftest-provision` —
Docker でビルドしたディスクに対する GPT (`work/out/steamos.img` は読み取り専用で開かれます。
`--reference-disk IMG`)、`work/cache/rootfs` キャッシュに対する CMS/squashfs、cpio、SHA-512 crypt。
セルフテストでは、ネットワークのメッセージ、ログのみのネットワーク/ファイルシステムの失敗、想定外のエラーの報告、
両方のスロットへのスパース/順次の rootfs コピーもチェックします。イベントを送信せずに実際の TLS の失敗を試すには、
`--selftest-provision` の実行時に、信頼されていない証明書を持つローカルサーバーを `STEAMAC_PROVISION_TEST_TLS_URL=https://localhost:PORT/`
で指定します。メッセージが表示され、レポートが生成されないことがチェックされます。

## 配布 (DMG)

`host/launcher/dist.sh` は、ビルドされた `work/out/FX Steam Launcher.app` をダウンロード用の
`work/out/dist/FX-Steam-Launcher-<version>.dmg` (アプリ + `/Applications` へのリンク) に変換します。
`SteamacBuildOut` キー (このビルドツリーへのパス) を除いたバンドルのコピーを、Developer ID、
Hardened Runtime、セキュアタイムスタンプで内側から順に再署名します: まずネストされた個別の Mach-O ファイルすべて
(`Frameworks/*.dylib`、`Resources` 内のヘルパープログラム、Sparkle の `Autoupdate`)、次にネストされたバンドルを
深いものから順に (Sparkle の `Updater.app`、`Sparkle.framework`)、最後に `steamac-vm.entitlements` (hypervisor、
disable-library-validation、audio-input。audio-input がないと Hardened Runtime は
マイクを黙ってブロックします) 付きでバンドル本体を署名します。アプリは公証されてステープルされ、続いて DMG が署名・公証・ステープルされます。
Gatekeeper はオフラインでも通過させます (初回起動時のおなじみの「インターネットからダウンロードされた」確認は
引き続き表示されます)。

```sh
host/launcher/build.sh      # fresh bundle
host/launcher/dist.sh       # signing, notarization, DMG
```

notarytool のプロファイルを一度だけキーチェーンに保存する必要があります:
`xcrun notarytool store-credentials steamac-notary --apple-id <Apple ID> --team-id V25VKGTW55
--password <app-specific password>`。変数: `STEAMAC_SIGN_IDENTITY` (デフォルトはキーチェーン内の唯一の
“Developer ID Application”)、`NOTARY_PROFILE` (デフォルトは `steamac-notary`)。
`--no-notarize` は署名のみで、ローカルでの確認用です (ダウンロードしたコピーは Gatekeeper に拒否されます)。

ライセンス: `bundle.sh` は、同梱コンポーネントのサードパーティライセンス文すべてと
`THIRD-PARTY-NOTICES.txt` インデックス (コンポーネント、バージョン、SPDX、バンドル内の場所、ソース。
`host/launcher/licenses.sh` が `work/out/licenses` に生成し、libkrun の crate と gvproxy/desync の Go モジュールも含みます) を
`Contents/Resources/licenses` に置き、さらにプロジェクトの `LICENSE` と `NOTICE` を
`licenses/steamac/` に置きます。`dist.sh` は `scripts/gpl-sources.sh` を呼び出し、DMG の隣に
`work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar` を置きます。これは GPL コンポーネントの完全なソース
コード (パッチと設定を含むカーネル、Debian スナップショットの busybox、
dosfstools、e2fsprogs、btrfs-progs、ビルドスクリプト、`README.txt`) です。GitHub のリリースに
DMG と一緒に添付してください。古いリリースの場合: `scripts/gpl-sources.sh v1.2`。

アプリ内アップデート ([アップデートの確認](privacy-and-updates.md#アップデートの確認)): `dist.sh` は `SUFeedURL` (`SPARKLE_FEED_URL`、デフォルトは
`https://fxgl.github.io/steamac/appcast.xml`)、`SUPublicEDKey` (`SPARKLE_PUBLIC_KEY`、デフォルトは `dist.sh` に固定された fxgl の
リリース鍵 `ML1BKHcTTwKlVSLtTdMvyk7Fhwg35VN1nUp+o4fezt8=`。インストール済みのコピーはこの鍵で署名された
アップデートだけを受け入れます)、`SUVerifyUpdateBeforeExtraction`、`SURequireSignedFeed` を追加します。公証付きビルドは
キーチェーンにその鍵の秘密鍵がないと失敗します (`generate_keys -p` は公開鍵を表示します)。
EdDSA 鍵ペアは `host/launcher/.build/artifacts/sparkle/Sparkle/bin/generate_keys` で一度だけ作成しました (Sparkle のツールは
SwiftPM パッケージに含まれ、組み込みのフレームワークと同じバージョンです): 秘密鍵は
ログインキーチェーンにだけあり、リポジトリや CI には決して置きません。オフラインでバックアップしてください (`generate_keys -x <file>`。
`generate_keys -f <file>` で別の Mac にインポートできます): これがないと、インストール済みのコピーには
どのアップデートも届かなくなります。`build.sh` は `CFBundleVersion` を `CFBundleShortVersionString` に設定します (Sparkle はこれでバージョンを並べます)。
リリースは次の順序で行います (フィードがまだアップロードされていないアセットを指すことがあってはなりません):

```sh
host/launcher/dist.sh
gh release create v<version> work/out/dist/FX-Steam-Launcher-<version>.dmg \
    work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar --notes-file <notes.md>
host/launcher/appcast.sh    # docs/appcast.xml, delta updates attached to the release
git commit -m "appcast: <version>" docs/appcast.xml && git push    # GitHub Pages publishes the feed
```

`appcast.sh` は、リリースの DMG がローカルのものと同じ (同じサイズ) であることを確認してから、Sparkle の
`generate_appcast` を `work/out/updates` (以前のバージョンのアーカイブ。フィードは
`docs/appcast.xml` から取得) に対して実行します: DMG の EdDSA 署名付きの新しい項目、
`LSMinimumSystemVersion` から取った最小 macOS、GitHub リリースのリリースノート (Markdown、埋め込み)、そのリリース上のダウンロード
URL。`work/out/updates` に DMG がある最大 3 つの以前のバージョンからのデルタアップデート
(カーネルとほとんどのヘルパーはめったに変わりません) は、スペースを除いた名前に変更され (GitHub はそのようなアセットの名前を変えるため)、
リリースにアップロードされます。フィード全体が署名されます。それ以外の引数は `generate_appcast` に渡されます。例:
`--phased-rollout-interval 86400` (アップデートが 7 日かけてユーザーに届きます) や `--critical-update-version ''`。
`docs/appcast.xml` を手で編集しないでください: 署名はファイル全体を対象としています。ローカルでのエンドツーエンドテスト:
2 つのバージョンについて `SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml` と
`SPARKLE_PUBLIC_KEY=<test key>` を付けて `dist.sh --no-notarize` を実行し、それぞれの後に `SPARKLE_KEY_FILE=<test private key>
host/launcher/appcast.sh --local http://127.0.0.1:8765` を実行し、
`work/out/updates-local` で `python3 -m http.server 8765` を実行します。
