# steamac — Apple Silicon 上の VM で動く Valve 公式 ARM64 SteamOS (Steam Frame イメージ)

[English](README.md) · [Русский](README.ru.md) · [简体中文](README.zh.md) · **日本語**

macOS 15 (Sequoia) 上で、Valve が Steam Frame 向けに提供している本物の SteamOS が、
Hypervisor.framework (libkrun) 上の軽量 VM で、Venus による GPU アクセラレーション付きで動作します。

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

Metal 上の Vulkan には、デフォルトで UTM フォークの MoltenVK (ジオメトリシェーダー、robustness2) +
`VK_EXT_depth_clip_enable` (PR #2712) + 私たちの修正を使います。KosmicKrisp (Metal 4 上の Mesa の Vulkan ドライバー)
は macOS 26 以降で使える実験的な代替です (「Vulkan ドライバー」を参照)。

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

これらを含むすべての設定は **Settings** ウィンドウ (下記参照) にあり、ドメインは
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

### LAN ネットワークと Steam Remote Play

通常のネットワークは gvproxy のユーザーモード NAT (SteamOS 内では `192.168.127.2`) を使います。LAN のブロードキャストは
この NAT を越えません。**Settings → Advanced → LAN Remote Play** (次回起動時)、または
`--lan-remote-play` で、ランチャー側の検出リレーと同じポート番号でのポート転送が有効になります:
Mac からゲストへの UDP **27031–27036**、TCP **27036–27037** です。これは**デフォルトでオフ**です:
有効にすると、SSH とは関係なく、Steam の Remote Play サービスが他のマシンに公開されます。
`--no-lan-remote-play` は 1 回の起動に限って無効にします。Network をオフにした場合も無効になります。

macOS の **Local Network** 権限を許可し、Mac/SteamOS のファイアウォールで受信トラフィックを許可してください。
Steam Link と Mac は**同じ IPv4 サブネット**上にある必要があります (Wi-Fi のクライアント分離、ゲスト
ネットワーク、VLAN、ルーティングを介した検出、IPv6 のみの LAN には対応していません)。ゲストの Steam で
Remote Play を有効にし、手動でペアリングするときは `192.168.127.2` ではなく Mac の LAN アドレスを使ってください。Steam Link は
スリープ中の SteamOS を復帰させられません: 再接続する前に、Mac のウィンドウ、Dock アイコン、またはコントローラーから復帰させてください。
ランチャーのログ付きの報告には、リレーの状態とカウンター、gvproxy の有効な転送とログ、
ゲストのアドレス、ルート、待ち受け中のソケットが含まれます (STEAMAC-9G)。
Mac 自身の Steam クライアントがこれらのポートを使っている場合は、終了してください: ランチャーは
UDP 27036 を共有も奪取もせず、競合を `remote-play: disabled for this boot` としてログに記録し、転送を元に戻します。
Mac の Steam クライアント自身が送る UDP 27036 のブロードキャストは、ゲストには中継されません。

リレーは Steam クライアントの ID と未知の protobuf フィールドを保持し、ステータスの
アドレスヒントを Mac の LAN IPv4 アドレスに置き換えます。転送には同じポート番号を使うため、
ポートはそのまま残します。ゲストのステータス通知は、5 秒ごとの実際の検出クエリで更新されます
(gvproxy はゲストサブネットからの自発的なブロードキャストを外に出しません)。Steam が応答しない場合に
ステータスを作り出すことはありません。サインアウト中のホストは Steam が通知しないことがあります。
`--selftest-remote-play` は VM を起動せずに、パケットの解析とアドレスの書き換えをチェックします。
実際の LAN でのプローブ (Mac 上または 2 台目のマシン上) には、次を実行します:
`python3 scripts/test/remote-play-discovery.py --bind <LAN-IP> --broadcast <subnet-broadcast> --expect-host <Mac-LAN-IP>`。
一時ポートを使い、実際の Steam の応答と書き換えたアドレスを表示し、
どのホストも応答しなければ失敗します。ペアリングやストリーミングの成功を示すものではありません。
プロトコルの参考資料: [Valve の Remote Play ネットワーク設定](https://help.steampowered.com/en/faqs/view/3E3D-BE6B-787D-A5D2)、
[Steam remote-client の protobuf](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_remoteclient_discovery.proto)、
[検出エンベロープのフレーミング](https://github.com/OpenSourceLAN/steam-discover/blob/master/listener.js)。

## Moonlight でのストリーミング

**Settings → Streaming → Enable Moonlight streaming** で、内蔵の GameStream ホストが
すぐに有効になります。これは**デフォルトでオフ**で、ウィンドウ表示の VM プロセスでのみ利用できます。信頼できるローカルネットワーク上の
別のデバイスに [Moonlight](https://moonlight-stream.org/) をインストールし、
macOS の **Local Network** へのアクセスと受信接続を許可して、Moonlight でこの Mac を選択します
(または Mac の LAN アドレスを手動で追加します)。そのデバイスに表示される 4 桁の PIN を
Mac のペアリングウィンドウに入力し、Moonlight で **SteamOS** を起動します。

Streaming タブには、ホスト/セッションの状態と、ペアリング済みのデバイスとそのペアリング日が表示されます。
**Revoke** はデバイスのアクセス権を取り消し、現在のストリームを終了します。そのデバイスは再度ペアリングが必要です。
**End stream** はアクセス権を取り消さずに現在のセッションを切断します。ストリーミングを無効にすると、
待ち受けが閉じられ、セッションが終了します。VM のサスペンドや SteamOS のスリープでもストリーミングは止まり、
待ち受けが閉じられます。設定が有効のままであれば、再開後に戻ります。
クライアントがストリーミングしている間は、ランチャーのバックグラウンド時にゲームを一時停止する設定はゲームを凍結しません。

有効な間、Mac は TCP **47984, 47989** で待ち受け、セッション中は TCP **48010** / UDP
**47998–48000** でも待ち受けます。Bonjour による検出には **_nvstream._tcp** を使います。これらの
ポートをパブリックなインターネットに公開しないでください。これは **Advanced → LAN Remote Play** とは独立しており、
Steam Link、ゲストの Steam Remote Play、仮想ディスプレイは必要ありません。

ストリームに含まれるのは、表示中の DXMT ゲームレイヤーを含むゲストのディスプレイと、ゲストで再生される
音声です。Mac のデスクトップ、ランチャーのオーバーレイ、マイクは含まれません。H.264 / 対応するハードウェア HEVC
と Opus を使い、画面収録の権限やオーディオのループバックドライバーは不要です。Moonlight が
要求した解像度が一時的にゲストのディスプレイを使います (VM の最大値以内の偶数サイズ)。
ストリームを終了するとウィンドウのサイズに戻ります。“Guest display
follows the window size” がオフの場合は、以前のゲスト解像度に戻ります。同時にストリーミングできるクライアントは 1 つです。キーボード、マウス、
マウスとしてのタッチ、コントローラーは、同じ実行中のゲストを操作します。ローカルとリモートの入力はゲストを共有します。
セッション中、Moonlight のコントローラーは Mac のコントローラーより先に SteamOS の最初のプレイヤースロットを使います。
**Additional controllers** がオフの場合、Mac のコントローラーはストリームが終わるまで待機します。
その後、Mac のコントローラーは通常のスロットに戻ります。
HDR、ネイティブのペン/タッチ、映像の暗号化は提供していません。信頼できる LAN で使ってください。
`--selftest-stream` は VM を起動せずに、コンポーネントのプロトコル/メディアのチェックを実行します。

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
| General | 起動/シャットダウンのオーバーレイ、GPU アイドル時の “Still working…” インジケーター、“When FX Steam Launcher is in the background”: **Mute sound** (デフォルトでオン: `krun_snd_set_volume(…, mute)` で約 150 ms かけて徐々にフェードアウトし、ウィンドウに戻ると音量が戻ります) と **Pause the game** (デフォルトでオフ: ゲストエージェントはフォーカス中のゲームだけを凍結します — `systemctl --user freeze app-steam-app<appid>-*.scope`、cgroup v2。Steam、ダウンロード、アップデートは動作し続けます。オンラインゲームは切断されることがあります)。エージェントが凍結を確認している間 (`game-frozen`/`game-thawed`)、ウィンドウは暗くなり、“Game paused · Click to resume” カードとタイトルの “— paused” が表示されます。ウィンドウをクリックするとゲームが再開し、そのクリックはゲストに渡されません。クラッシュレポート (`--no-crash-reports`、後述)、**Check for updates at startup** (デフォルトでオン、「アップデートの確認」を参照)、フレーム統計のログ (`--perf-stats`)、**Use the Mac's keyboard layouts in Desktop Mode** (デフォルトでオン、「デスクトップモード」を参照) | 起動時のフルスクリーン、**Use the Mac's time zone and clock format** (デフォルトでオン、前述) |
| Display | ゲストがウィンドウサイズに追従、ウィンドウ右上の Apple の Metal Performance HUD (Ctrl+Cmd+P、View → Show Metal Performance HUD)、**MetalFX super resolution** (デフォルトでオフ): ウィンドウのピクセル数がゲストより多いとき (Retina 画面、拡大縮小された、またはフルスクリーンのウィンドウでは 2 倍)、リニア / ニアレストの拡大の代わりに、Apple の MetalFX 空間アップスケーラーでゲストの画像をウィンドウのピクセルサイズに拡大します。ランチャー内でゲストのフレームに対して実行されるため、すべてのゲームと Steam の UI で動作します | 物理サイズの取得元 (ディスプレイから自動 / DPI / mm — `--dpi`、`--display-mm`)、リフレッシュレート (`--refresh`)、ウィンドウサイズ (`--display`): 1280 × 800 (Steam Deck) から 3840 × 2560 までの標準的な 16:10、16:9、21:9、3:2 の解像度 (ディスプレイに収まらないものには “larger than this screen” と表示され、ウィンドウは従来どおり縮小されます)、“Fit to screen” (ディスプレイに合う最大サイズ、起動のたびに再計算)、または “Custom…” (W × H のフィールド)。**Retina resolution** (任意、デフォルトでオフ): ゲストのディスプレイは、同じ EDID の物理サイズのまま画面のピクセル密度 (ウィンドウのポイント × 画面のバッキングスケール。起動時に取得し、どの辺も 4094 px を超えないようにスケールを下げます) になります。そのため SteamOS は UI を同じサイズまで拡大し、文字がくっきり表示されます。ただしゲームは 4 倍のピクセルを描画し、各フレームのコピーも 4 倍の大きさになります。代わりにおすすめの設定: Retina resolution をオフ + MetalFX super resolution (Retina 画面では 2 倍のアップスケール) |
| Mouse | ゲーム内での自動キャプチャ、ゲームの一覧 (`appmanifest_<appid>.acf` からの名前、Default/Auto/Off、削除) | — |
| Controller | 仮想パッドを操作する物理コントローラー (GameController) (最初に接続されたもの、または選択したもの)、SteamOS にパッドを渡すかどうかと何として見せるか (`--no-gamepad`、`--pad`、「コントローラー」を参照)、DualSense をそのままパススルーするかどうか、追加のコントローラーをプレイヤー 2–4 にするかどうか、A/B と X/Y の入れ替え、スティックのデッドゾーン、ライブ入力テスト | — |
| Sound | 出力デバイス (System default は macOS に追従、または特定の CoreAudio デバイス)、音量/ミュート、Low/Normal/Safe のバッファ — `krun_snd_set_*` 経由 (`dlsym` で検索します。古い libkrun ではフィールドが無効になり、説明が表示されます) | サウンド (`--no-sound`) |
| Games | **Share game statistics** (同意するまでオフ、「ゲーム統計」を参照)、既知のゲームとセッションが記録されたゲーム: ゲームごとのプロファイル (グラフィックス、Vulkan ドライバー、起動オプション。後述)、セッション、プレイ時間、前回のセッションの FPS / 1% low / ゲームのメモリ / Vulkan ドライバー、任意の評価 (Runs well / Playable with issues / Starts, but unplayable / Does not start)、ゲームごとの **Share** スイッチ | プロファイルによっては Steam または VM の再起動が必要です (後述) |
| Advanced | — | vCPU (`--cpus`)、RAM (`--mem`)、SSH の有効/無効 + ポート (`--ssh-port`、`--no-ssh`) と生成されたパスワード、ネットワーク (`--no-net`)、ディスクイメージ (`--disk`)、Create New Disk…、Steam クライアント (`--steam-client`、「Steam クライアント」を参照)、Vulkan ドライバー (`--vulkan-driver`、「Vulkan ドライバー」を参照)、Allow DXMT (D3D11 on the Mac's Metal)、実験的機能 (`--wmtr-lib`、`--no-wmtr`、「Vulkan ドライバー」を参照)、共有フォルダー + SteamOS 内のマウントポイント + Steam ライブラリとしての使用 (`--share`、`--share-mount`、`--no-share`、`--share-library`、`--no-share-library`、「共有フォルダー」を参照) |

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

**Recommended: … — Apply** は、この Mac の **My Mac** の条件
(GPU コア数、RAM、パフォーマンスコア数がこの Mac 以下) で、統計サービスからプロファイルを取得します。構成は
`(runs well + 0.5 × playable with issues) / all ratings` で順位付けされ、次に起動の成功率が高く、
早期終了が少ないものが優先されます。少なくとも 2 つの異なるインストールが必要です (詳細は「ゲーム統計」を参照)。
推奨が自動で適用されることはありません: プロファイルを変更するのは **Apply** だけです。

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

## デスクトップモード

Steam → Power → **Switch to Desktop** で KDE Plasma が起動し、デスクトップの **Return to Gaming Mode** アイコンで
戻ります。Steam Frame のイメージではこのモードは VR デスクトップです (`plasma-session.target` が
SteamVR を必要としますが、VM はそれをマスクします)。そのためレイヤーがこれを置き換えます: `plasma-session.target` と
`steamac-nested-desktop.service` が、同じ gamescope の中で Plasma を 1 つの KWin ウィンドウとして実行し
(`/usr/lib/steamac/nested-desktop`、Valve の `steamos-nested-desktop` と同様)、ディスプレイのサイズに合わせるため、
gamescope はそれを 1:1 で表示します。`gamescope-onready` はそのサービスを待ちます: Plasma が終了するとセッションが
終了し、SDDM が再ログインします。Plasma は専用のランタイムディレクトリと D-Bus セッションバスを持ちます。レイヤーの
`steamosctl` シム (`/usr/lib/steamac/desktop-bin`、その PATH の先頭) は、Return to Gaming Mode などの SteamOS コマンドを
steamos-manager が動作する外側のセッションバスに送ります。デスクトップの Steam
自動起動 (`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`) は、標準の `-deckard` (Frame クライアント) ではなく
ランチャーで選んだクライアントを維持します。標準のままでは切り替えのたびにもう一方のクライアントを
ダウンロードしてしまいます。進行状況エージェントは `focus desktop <w>x<h>` (Plasma ウィンドウ) を報告します: ランチャーは
相対ポインターを維持し、gamescope の拡大縮小に合わせてそのウィンドウにマッピングします。また、デスクトップモードに直接
起動した場合 (`steamos-session-select plasma-persistent`) は、デスクトップが起動した時点で `ready` を報告します。

**キーボードレイアウト。** Settings > General の **Use the Mac's keyboard layouts in Desktop Mode** (デフォルトで
オン、即時適用) を有効にすると、デスクトップモードでは Mac で有効なキーボードレイアウトが入力
メニューの順に使え、Mac の入力ソースに合わせて切り替わります (地球儀キー、Control-Space)。ランチャーは
それぞれを XKB レイアウトに対応付けます (`com.apple.keylayout.Russian` → `ru(mac)`、`RussianWin` → `ru(winkeys)`、
`German` → `de(mac)`、…。それ以外は曖昧さのない第一言語の限られたリストのみ。不明な
ソースはスキップされ、インプットメソッドはそれが入力に使うレイアウトとして扱われます)。送られるレイアウトは最大 4 つ
(XKB の上限) で、常にアクティブなものを含み、`keyboard-layout <active index> <layout(variant)>…` として
`fx.progress` 経由で、変更のたびとデスクトップモードがフォーカスを得るたびに送られ、さらに 1.5、4、8 秒後にも再送されます
(Plasma の起動処理は、KWin がこちらのレイアウトを受け取った後で自身の最初のレイアウトを選ぶためです)。エージェントは
`/usr/lib/steamac/desktop-keyboard` を実行します (最新の要求のみで、決してブロックしません): 各レイアウトと
バリアントをゲストの XKB シンボルと照合し、不明なものを除外してアクティブなインデックスを再計算します
(アクティブなレイアウトが除外された場合は切り替えません)。Mac の時刻形式と同様に、SteamOS で変更されるまでは
Mac に従います: 最初の同期では既存のカスタムレイアウトも置き換えますが、それ以降は
Plasma のレイアウトをユーザーが編集したことが検出されると、そちらが恒久的に優先されます。マーカーは
`~/.config/steamac/mac-keyboard.json` です。設定をオフにすると同期は止まりますが、
以前のリストは復元されません。追従中は `kxkbrc` (空の `DisplayNames` を含む) を書き込み、ファイルが変わったときや KWin の
レイアウトコードが異なるときに KWin に再読み込みを依頼し (`org.kde.keyboard` `/Layouts` の `reloadConfig`)、
稼働中のネストされたセッションバス上でアクティブなレイアウトを選択します (`org.kde.KeyboardLayouts.setLayout`)
(`nested_plasma/steamac-session-bus`。バスがない、または古い場合は何もしません)。macOS は地球儀キーでの切り替えの
0.55–0.85 秒後に入力ソースの通知を送ることが多いため、この設定がオンで、
デスクトップモードにフォーカスがあり、ランチャーがアクティブな間だけ、30 ms ごとに現在のレイアウトをポーリングします。
キーは Mac の物理キー (evdev コード) のままで、何が入力されるかはレイアウトが決めます。
ゲームモードは独自のレイアウトを維持します。

Flatpak アプリ (Discover) は bubblewrap の中で動作し、bubblewrap はユーザー名前空間に独自の procfs をマウントします。カーネルは
マウント名前空間内のいずれかの procfs が完全に見えている間しかそれを許可せず、initramfs は
合成した `/proc/cmdline` を本物の上にバインドします。そのため、手を加えていない procfs も
`/run/steamac/proc` (`nosuid,nodev,noexec`) にマウントします。これがないと、すべての Flatpak アプリが `bwrap: Can't mount
proc on /newroot/proc: Operation not permitted` で終了します。

デスクトップモードは `plasmashell` を `/usr/lib/steamac/desktop-shell` の下で実行します: ネストされたセッションには systemd
ユーザーマネージャーがないため、標準のサービスの再起動は適用されず、Wayland のプロトコルエラーでシェルが
クラッシュハンドラーなしに終了 (`_exit`) し、KWin ウィンドウだけが残った黒いデスクトップになってしまいます (STEAMAC-AJ/9P)。
異常終了の後はシェルを再起動します (1 分あたり最大 3 回)。通常のログアウトやシェルの
終了では再起動しません。問題レポートには、デスクトップのパッケージのバージョンと、シェルと
コンポジターのジャーナルが含まれます。

## クリップボード

Settings → General → **Share clipboard with SteamOS** (デフォルトでオン、即時適用): Mac でコピーしたテキスト (UTF-8)
と PNG 画像を SteamOS で貼り付けられ (Ctrl+V — Steam のテキストフィールド、ゲーム、
デスクトップモードのアプリで)、その逆も可能です。上限はテキストが 1 MiB、画像 1 枚あたり 16 MiB です (それより大きい
項目はログに 1 行記録してスキップされます)。パスワードマネージャーが秘匿または一時的とマークした項目
(`org.nspasteboard.ConcealedType` / `TransientType`) は、**Include concealed
(password manager) items** がオンでない限り Mac に留まります。ランチャーは、アプリがアクティブで VM が動作している間だけ
0.5 秒のタイマーでペーストボードの `changeCount` を確認し、アクティブになるたびにも 1 回確認します — バックグラウンド、
サスペンド中、スリープ中には決して確認しません。SteamOS からの画像は Mac に PNG + TIFF として届きます。

転送: virtio-console ポート `fx.clipboard` 上の、フレーム化されたバイナリメッセージです (`HELLO` / `STATE` /
シーケンス番号付きの `SET` / `ACK`。`host/launcher/Sources/steamac-vm/Clipboard.swift`、
`guest/progress-agent/src/clipboard.rs`)。ゲストでは、ユーザーサービス
`fx-clipboard-agent.service` (`fx-progress-agent clipboard`、ゲーミングセッションとデスクトップ
モードのセッションが必要とします) が、gamescope の **両方の** Xwayland サーバー (`:0` は Steam、
`:1` はゲーム) で `CLIPBOARD` (XFixes。TARGETS、UTF8_STRING、text/plain;charset=utf-8、
TEXT、STRING、image/png、256 KiB を超える場合は INCR) を所有して監視します: gamescope はセレクションを引き取ることで
両者の間でプレーンテキストを自ら同期しますが、画像や INCR サイズのテキストは同期しません。デスクトップモードでは、
`zwlr_data_control_manager_v1` (存在すれば `ext_data_control_manager_v1`) を通じて Plasma セッションの Wayland クリップボードも使います。
そこでは X11 ウィンドウがアクティブな間、KWin がそれを X11 アプリに橋渡しします。エコーの抑制は内容によって行います: 双方が
最後に送った、または引き取った内容を覚えているため、gamescope、KWin、Klipper が何度再通知しても、
1 回のコピーは 1 回の転送になります。ディスプレイが現れた時点で存在するセレクション (例:
Klipper が復元した履歴) は Mac に送られず、代わりに共有されている内容がそこで提供されます。
`--control-fifo` には `chord KEYCODE ctrl` (例: `chord 9 ctrl` = ゲスト内の Ctrl+V) と
`set shareClipboard on|off` があります。

## 共有フォルダー

**Settings → Advanced → Shared folder** (次回起動時) は、1 つの Mac フォルダーを、タグ `macshare` の
virtio-fs デバイスとして SteamOS に公開し、起動のたびに **Mount point in SteamOS** (デフォルトは
`/home/steamos/MacShare`) にマウントします。ファイルはその場で読み書きされ、何もコピーされません:
Mac に保存したゲームは Mac のディスクの速度で読み込まれ、SteamOS がそこに書き込んだものはすぐに Mac に
反映されます。デフォルトではオフです (フォルダー未選択)。コマンドライン: `--share DIR`、`--share-mount PATH`、
1 回の起動に限って無効にする `--no-share`。

フォルダーを共有すると、**Use as a Steam library** がデフォルトでオンになります (次回起動時)。
SteamOS は Steam の起動前に **`<mount>/SteamLibrary/steamapps`** を作成して `<mount>/SteamLibrary` を登録するため、
デスクトップモードの “Add Drive” ダイアログは不要です。Steam のストレージ設定と
インストール先の選択画面では、**Mac Share** という名前の 2 つ目のライブラリとして表示され、Deck のような
フォーマットが必要なリムーバブルドライブにはなりません。`--share-library` / `--no-share-library` で 1 回の起動に限ってこれを上書きできます。
オフにしてもファイルは削除されず、登録済みのライブラリも削除されません。

登録は **ゲストのライブラリパスごとに 1 回** です。後で Steam で削除した場合は、別の共有を選んで
元に戻した後もその削除が尊重されます。マーカーは
`~/.local/share/Steam/config/steamac-share-library.json` (`config.vdf` の隣) です。削除したパスを
再び自動で登録するには、Steam を停止した状態でマーカーからそのパスを削除してください。
ゲストのマウントパスを同じにしたまま Mac のフォルダーだけを変更しても、再登録はされません。

**ファイルシステム: APFS を推奨します。** Proton は各ライブラリの
`steamapps/compatdata` に Windows のプレフィックスを保存し、これには書き込み可能なゲームファイルだけでなくシンボリックリンクが必要です。フックは
マウントした共有上で `steamos` としてシンボリックリンクの作成と追跡を試し、
失敗した場合は登録をスキップします (シンボリックリンクのない exFAT も含みます)。Mac OS 拡張/HFS+ はシンボリックリンクに対応しており、
ファイルシステム名で除外されることはありません。APFS の virtio-fs 読み書き、chmod、Proton 11 ARM64 プレフィックスの
`dosdevices/c:` / `z:` シンボリックリンクは VM 内で確認済みです。通常の大文字小文字を区別しない APFS の共有は、Linux でも
大文字小文字を区別しないままです: 大文字小文字だけが異なるファイル名を必要とするゲームには、引き続き
大文字小文字を区別するボリュームか VM 内部のライブラリが必要です。これは Mac/Windows の Steam
ライブラリを Linux 用に変換するものではありません。SteamOS には別のフォルダーを使ってください。

実装: `steam-share-library` は `steam.service` のブロックしない `ExecStartPre` で、
`steamac.share=PATH` とともに `steamac.share_library=1` で有効になります。ファイルに触れる前に、
`findmnt -t virtiofs` で **正確なマウントポイント** を確認します。テストした Deck クライアント
(1792618285) は、まず `~/.local/share/Steam/steamapps/libraryfolders.vdf` を読み、存在しなければ
`config/libraryfolders.vdf` にフォールバックし、両方を同じ内容のコピーとして書き直します。フックは
正となるファイルをアトミックに編集し、既存の番号付きエントリーを保持します (または
従来のファイルを取り込みます)。フックが与えるのは `path` と `label` だけです。`contentid` の割り当て、
`totalsize` の計測、`apps` の設定は Steam 自身が行います。推測した ID やインストール済みアプリの記録は書き込みません。
以前登録した共有がない場合、Steam は **エントリーを保持したまま “Install folder …
not mounted” をログに記録します**。共有が戻るまで、そこはインストール先として使えません。その場合フックは
リストとマーカーの両方に手を加えず、ゲストのディスク上に代わりのライブラリを作成することもありません。
外部ボリュームは VM を起動する前に接続しておいてください。接続されていない場合は、接続し直して再起動してください。

ランチャーは `krun_add_virtiofs4` でデバイスを追加し (`KRUN_SEMANTICS_LINUX_SIMPLIFIED`: ゲストには
すべてのファイルが自身の uid/gid に見えるため、`steamos` ユーザーは所有者の
マッピングなしで読み書きできます。DAX ウィンドウはありません)、カーネルコマンドラインで `steamac.share=PATH` を渡します。initramfs
(「shared folder」セクション) はパスを確認し — `/home/steamos/` のサブディレクトリで、空、`.`、`..` の
要素がなく、`[A-Za-z0-9/_.-]` のみであること — `multi-user.target` が必要とするランタイムのマウントユニット
(`/run/systemd/system/<path>.mount`、`What=macshare`、`Type=virtiofs`、`TimeoutSec=15`) を
書き込みます。このユニットは `steamos-create-homedir.service` を必要とし、その後、ユーザー
セッションの前に実行されます: 新しいディスクでは、systemd がマウントポイントを作成する前に SteamOS がユーザーのホームを作成して
中身を用意する必要があります。そうしないと、ホームが root 所有になり、スケルトンがスキップされてしまいます。ユニットには
`local-fs.target` より前に順序付けられないように `DefaultDependencies=no` があります (ホームの作成はもっと後で行われます)。
シャットダウン時のアンマウントの通常の順序付けは維持されます。共有に失敗しても起動は妨げられません。ユニットは
ランタイムのユニットマスクと同様、その起動の間だけ存在します。起動時に存在しないフォルダー
(外部ドライブの取り外し、名前の変更) はログに記録してスキップされ — ランチャーは共有なしで起動します。
起動を拒否するのは明示的な `--share` の場合だけです。Settings の行には、見つからないものとして赤で表示されます。

**セキュリティ。** libkrun のセキュリティモデルにより、virtio-fs はゲストを共有
ディレクトリに閉じ込めません: macOS ではルックアップが `..` をフィルタリングせず、ランチャーはサンドボックス化されていません。共有を
設定すると、SteamOS の root (そこで root を取得したもの: ゲーム、Flatpak、Proton の脆弱性の悪用) は、
Mac のユーザーが読めるものをすべて読み、そのユーザーが書ける場所に書き込める可能性があります。共有は
信頼できる SteamOS とだけ行い、必要ないときはオフにしておいてください。SSH は関係ありません。

## コントローラー

macOS の GameController フレームワークが対応するコントローラー (Xbox、DualSense、DualShock 4、MFi、…) なら、どれでも
SteamOS のゲームパッドを操作できます: 最初に接続したもの、または Settings → Controller で選んだものが
プレイヤー 1 になり、それ以降のものはプレイヤー 2–4 になります (後述の「複数のコントローラー」)。このパッドは virtio-input
デバイスではありません: ランチャーは virtio-console ポート `fx.pad` を通じてゲストの root サービス
`fx-pad.service` (`fx-progress-agent pad`、ポートが現れたときに udev が起動します) にパッドを送り、そのサービスが
uinput でパッドを作成します。そのため VM の動作中は Mac に追従します: コントローラーが接続すると現れ (Steam が
“Controller Connected” と表示します)、そのコントローラーがなくなると消え、コントローラーに合わせて種類も変わります。
Settings → Controller → **Appears in SteamOS as** (`--pad auto|xbox360|dualsense|dualshock4|steamcontroller`
で 1 回の実行に限って指定):

- **Automatic** (デフォルト): 操作しているコントローラーと同じ種類 — DualSense (または Edge) →
  DualSense、DualShock 4 → DualShock 4、それ以外 → Xbox 360 コントローラー。Steam Controller は
  そのまま SteamOS に渡されます (後述の「Steam Controller のパススルー」);
- **Xbox 360 controller**: カーネルの `xpad` ドライバーが公開するもの (`045e:028e`);
- **DualSense** / **DualShock 4**: USB パッドに対して `hid-playstation` / `hid-sony` が公開するもの
  (`054c:0ce6` / `054c:09cc`、バージョン `0x8111`、フェイスボタンは位置で対応、アナログトリガーに加えてデジタルの
  L2/R2)。Steam の SDL はこれを PS5 / PS4 コントローラーとして対応付け、PlayStation のボタン表示を使います;
- **Steam Controller**: Steam Controller はそのまま SteamOS に渡され、それ以外のコントローラーは
  Xbox 360 コントローラーを操作します。

**Home / PS ボタンの診断。** ランチャーはこのボタンを SteamOS に任せるよう macOS に要求しますが、
macOS がその設定を上書きすることがあります。USB では動くのに Bluetooth では動かない場合は、
Settings → Controller のライブの **Home** インジケーターを比べ、それぞれの接続でボタンを押して離した後に
レポートを送ってください。ランチャーのログには、GameController が Home を公開しているか、
そのシステムジェスチャーの割り当て、ボタンとプロファイルのコールバック、Home イベントが
ゲストのパッドポート向けにキューに入ったかが記録されます。`pad state` には現在の Home の状態が含まれます。これにより、Bluetooth での失敗を
DualSense のパススルーの問題だと決めつけずに (DualShock 4 は仮想パッドを使います)、ホストでの入力
処理とゲストへの配信を区別できます。`pad state` と、ランチャーのログを含む問題レポートの `controllers.txt` には、
受動的な HID の一覧 (ID、名前、トランスポート、用途、そして各デバイスがルーティングされる、またはされない理由。
除外されたデバイスは決して開かれず、入力監視も要求されません) と、
最新の DualSense のスティック、生のモーションセンサー、タッチのスナップショットとその経過時間も含まれます (STEAMAC-8R/8V)。

**振動。** パッドは本物のドライバーと同様に `FF_RUMBLE` を持つため、SDL と Steam が振動させます — Steam Input を
経由するゲームは Steam の仮想 Xbox パッドを通じてこれに届きます。uinput は再生をユーザー空間の
ドライバーに任せます: `fx-pad` はカーネルの ff-memless のルール (遅延、長さ、繰り返し、再アップロード、
エフェクトの合算) を実装し、合成したレベル `rumble <strong> <weak>` をランチャーに送ります。ランチャーは
GameController のハプティクスでそれを再生します: 強いモーターは左のグリップ、弱いモーターは
右のグリップです (グリップが分かれていないコントローラーではどこでも同じレベル)。VM が
一時停止している間は何も再生しません。ポートのプロトコル: `guest/progress-agent/src/pad.rs`。タッチパッド、ジャイロ、ライトバー、アダプティブ
トリガーは本物のコントローラーの HID 機能であり、この evdev デバイスは持っていません。

**DualSense のパススルー。** DualSense (または Edge) がパッドを操作していて、パッドが
DualSense として表示される場合、Settings → Controller → **Pass a DualSense through** (デフォルトでオン、即時適用) により、
uinput パッドの代わりにコントローラーそのものを SteamOS に渡します。ランチャーはそれを生の HID デバイスとして開き
(IOHIDManager、占有はしません: GameController は引き続きそれを選択し、スリープ中のゲストを起こします)、
`fx-pad` が `/dev/uhid` でそれを再作成します: レポートディスクリプター、ベンダー/プロダクト、USB または Bluetooth の
バスは同じです。ゲストの `hid-playstation` ドライバーは、接続されたコントローラーと同じようにそれにバインドし (ゲームパッド、
タッチパッド、モーションセンサー、ライトバーとプレイヤー LED、ミュート LED)、Steam は `/dev/hidraw*` 上で独自の HIDAPI
DualSense ドライバーを使います。そのため Steam Input はタッチパッド、ジャイロ、ミュートボタンを得て、
振動、ライトバー、アダプティブトリガーを自ら制御します。入力レポートはそのままゲストに送られ
(`hid-input`)、出力レポート、GET_REPORT、SET_REPORT はコントローラーに戻されます (`hid-output`、
`hid-get` / `hid-get-reply`、`hid-set` / `hid-set-reply`、レポート ID を先頭にした 16 進数)。
ゲストの処理が遅れている間は、古い入力レポートはキューに溜めずに破棄されます: 各レポートが状態の全体を
持っているためです。A/B の入れ替えとスティックのデッドゾーンは、パススルーしたコントローラーには適用されません。GameController
はコントローラーがどの HID デバイスかを教えてくれません: 複数の DualSense が接続されている場合は、最初に
見つかったものがパススルーされます。`caps hid` のない古いゲストレイヤーでは、引き続き uinput パッドが使われます。

**汎用の HID ジョイスティックとゲームパッド。** **Automatic** は、GameController が公開しない Generic Desktop (usage page 1)
の Joystick (4) と Game Pad (5) デバイスも
そのままパススルーします: たとえば DJI FPV Remote Controller 2 (`2ca3:1020`) や Spektrum SLT6
(`35cf:04fb`) です。既存の生 HID/uhid の経路がディスクリプター、ID、レポートを保持し、
レイアウトとキャリブレーションはゲストの `hid-generic`、SDL、Steam が処理します。これは Xbox のエミュレーションではありません:
デバイスの設定はランチャーのライブの GameController 入力テスト、
A/B の入れ替え、デッドゾーンではなく、SteamOS/Steam Input で行ってください。`caps hid` のある最新のゲストレイヤーが必要です。
SpaceMouse のような Multi-axis Controller (8) は、意図的にデフォルトではマッチさせていません。

各デバイスは、ゲストのサービスが HID に対応している、空いている使用可能なプレイヤーのうち最も小さい番号を取り、
4 人のプレイヤーを GameController や Steam Controller と共有します (プレイヤー 2–4 を使うには **Additional controllers** を
有効にしてください)。空いている間はそのプレイヤーを保持しますが、GameController のコントローラーには譲って
次の空いているプレイヤーに移るか、空きがなければ待機します。BLE の Steam Controller の予約は
固定されたままで、押し出されることはありません。汎用デバイスは、`caps hid` のない古いゲストではプレイヤーを予約できず、
一時停止した VM を起こすこともできません。汎用デバイスの検出とパススルーを止めるには、**Virtual controller** (`--no-gamepad`) をオフにするか、
**Appears in SteamOS as** で明示的な種類を選んでください。
`pad state` には、各汎用コントローラーの名前、VID/PID、レジストリ ID、予約したプレイヤーが表示されます。

入力の重複を避けるため、汎用 HID が GameController の所有となるのは、
`GCController.supportsHIDDevice` が true (HID のレジストリ ID ごとにキャッシュ) **かつ**、公開されている
`GCController.controllers()` のエントリーの `vendorName` または `productCategory` が、大文字小文字を無視し空白をまとめたうえで、
HID のプロダクト、製造元、または「製造元 プロダクト」と完全に一致する場合だけです。
コントローラーと HID を結び付ける公開された方法はなく、これは名前の一致であって VID/PID の推測ではありません。
対応しているデバイスは、非同期の公開を待つため、検出後 **2 秒間** 開かずに待機します。
一致するコントローラーがなければ、その後は汎用 HID としてパススルーされます。macOS が対応を表明している場合でも、
DJI C5 も同様です。後から一致する GC の接続があると、プレイヤーの割り当ての前に汎用の経路を
解放し、その接続が切れると HID デバイスを再び提供します。保留、受け入れ、
GC 所有によるスキップ/解放は、状態が変わるたびに VID:PID とプロダクトとともに 1 回ログに記録されます。
DualSense と Valve のデバイスは既存の経路を維持します。
検出には独立したデバイスの IOHIDManager を使います: マッチングでは
関係のないデバイスを開いたり、入力監視を要求したりしません。通常のジョイスティック/ゲームパッドのコレクションには
その権限は不要です。キーボード/マウス/トラックパッドのコレクションを持つ複合コントローラーを接続した場合は
必要になることがあり、それを要求できるのは受け入れたコントローラーを開くときだけです。Apple はそれらのコレクションを
[IOHIDDevice](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.cpp) でマークしており、
その [device plugin](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDLib/IOHIDDeviceClass.m)
は usage のマッチング時ではなく、開くときにアクセスを要求します。

**Steam Controller のパススルー。** **Appears in SteamOS as** が Automatic または Steam Controller の場合、
Steam Controller (2026) は同じ uhid の経路でそのまま SteamOS に渡されるため、Steam は独自のドライバーで
トラックパッド、ジャイロ、背面ボタン、ハプティクスを制御します。単独ではプレイヤー 1 になります。
**Additional controllers** がオンの場合、別のコントローラー (たとえばプレイヤー 1 の
DualSense) と並んだ Steam Controller は、除外されずに次の空いているプレイヤーになります:
- Bluetooth LE で Mac に接続した場合 (`28de:1303`): 独自の ID と Bluetooth バスでパススルーされます。
  GameController には表示されないため、GameController のコントローラーを必要とせず、
  スリープ中のゲストを起こすこともできません (VM が一時停止している間、HID 入力は破棄されます);
- USB で Mac に接続した場合 (`28de:1302`): 独自の ID と USB バスでパススルーされ、
  Bluetooth と同じく入力監視が必要です。1 つの USB コントローラーを対応する GameController の代役と
  曖昧さなく対応付けられる場合、HID はそのプレイヤーの枠を、余分な Xbox
  360 パッドなしで保持します。BLE のパススルーは他の GameController パッドを抑制しません;
- Puck 経由の場合 (`28de:1304`): Puck のインターフェース 2–5 がコントローラーの枠で、
  コントローラー自身のレポートディスクリプターを持ちます。SDL と Steam は Puck のコントローラーを USB のインターフェース
  番号でしか扱わず、uhid デバイスにはそれがないため、コントローラーの状態を運ぶ枠は
  有線の Steam Controller (`28de:1302`、USB バス) として SteamOS に渡されます。コントローラーの状態が
  2 秒間ない枠は再び削除され (コントローラーのオフ、別の枠や Bluetooth への移動)、
  Puck の GameController パッドが引き継ぎます。**デスクトップモード** では猶予は 30 秒で、ワイヤレスの状態以外のすべての入力
  レポートが枠を維持します。これにはリザードモードのキーボード/マウスや
  バッテリーのレポートも含まれます。これにより、デスクトップでの使用中も、
  Options でコントローラーを起こした後も、Valve のパススルーが安定します。ワイヤレスの状態はどちらのタイムアウトも延長せず、切断の
  状態はどちらのモードでも枠を直ちに削除します。デスクトップモードに切り替えても、
  ゲームモードの 2 秒のタイムアウトですでに期限切れになった枠は復活しません。そのプレイヤーの Steam Controller が
  パススルーされるのは、ちょうど 1 人のプレイヤーの GameController のコントローラーが Steam Controller で、
  かつ稼働中の Puck の枠がちょうど 1 つの場合だけです。それ以外の場合、枠をコントローラーと確実に
  対応付けられないため、それらのプレイヤーは uinput パッドを使い続けます。

そのレポートディスクリプターにはキーボードとマウスのコレクション (コントローラーのデスクトップモード) があるため、macOS は
System Settings → Privacy & Security → **Input Monitoring** が許可されている場合にしかそれを開きません: ランチャーは
許可を求め、許可されるとすぐにデバイスを開きます (`hid passthrough: Input Monitoring granted, reopening the HID manager`)。
コントローラーにこの権限が必要な場合、Settings → Controller に警告が表示され、
アクセスを要求して該当する System Settings のパネルを開く **Mac Input Monitoring Settings…** ボタンが表示されます。
警告は Steam Controller または汎用 HID のマッチングが有効な間だけ表示されます。アクセスがすでに
有効なのにコントローラーが使えない場合は、ランチャーを再起動してください。
macOS は Bluetooth LE の Steam Controller の 64 バイトのフィーチャーレポート 1 (Steam のコマンドチャネル) を
65 バイトとして返すため、そのコントローラーの Bluetooth の GET_REPORT バッファーだけがディスクリプターの
サイズより余裕を持っています。USB の DualSense にはディスクリプターのサイズそのままが使われます (1.9.9 では余裕を持たせたことで
ファームウェアのレポート 32 がタイムアウトしました。STEAMAC-84)。切断されたコントローラーは、ランチャーが保持する
デバイス参照によって削除されるため、USB や Bluetooth で再接続すると新しいデバイスがパススルーされます。

**複数のコントローラー。** Settings → Controller → **Additional controllers** (デフォルトでオン、
即時適用) を有効にすると、それ以降に接続したコントローラーはプレイヤー 2–4 になり、それぞれが SteamOS に独自のゲームパッドを持つため、
ローカル協力プレイができます。各プレイヤーには virtio-console ポートがあります: 前述のとおりプレイヤー 1 は `fx.pad`、
そして `fx.pad2` … `fx.pad4` で、それぞれポート名にちなんで名付けられた `fx-pad@.service` のインスタンスが担当します
(`FX_PAD_PORT` を付けた同じ `fx-progress-agent pad` で、udev が起動します)。そのため、ポート上のプロトコルは
すべてのプレイヤーで同じで、パッドの振動はそのパッドを操作しているコントローラーで再生されます。プレイヤーが
コントローラーを得るのは、そのポートのゲストのサービスが `hello` を送った後です: `fx-pad@.service` のない
ゲストレイヤーでは 1 つのパッドのままです。Settings で選んだコントローラーは、
Bluetooth LE の Steam Controller がすでにそのプレイヤーを占めていない限り、プレイヤー 1 になります。プレイヤーは
コントローラーが切断されるまでそれを保持し (他のプレイヤーは繰り上がりません)、再接続したコントローラーは最初の空いているプレイヤーになります。
Bluetooth LE の Steam Controller もプレイヤーを保持します: 小さい番号のプレイヤーが切断しても
繰り上がらず、新たに接続した GameController のコントローラーに押し出されることもありません。BLE の
コントローラーを切断するとそのプレイヤーは空き、再接続すると空いている使用可能なプレイヤーのうち最も小さい番号を取ります。
**Appears in SteamOS as**、A/B の入れ替え、デッドゾーンはすべてのパッドに適用されます (
Automatic では各パッドがそれぞれのコントローラーの種類になります)。パススルーされるのはプレイヤー 1 の
DualSense だけで、別のプレイヤーのコントローラーも DualSense の場合はパススルーされません
(GameController はどの HID デバイスが誰のものかを教えてくれません): その場合は両方とも uinput パッドになります。Steam
Controller は、空いている使用可能などのプレイヤーでもパススルーされます (前述)。VM の
動作中は、Settings → Controller のライブ入力テストで、各コントローラーにそのプレイヤーのバッジ
(**Player 2**) が表示されます。オフの場合: プレイヤー 1 だけが使われます。BLE の Steam Controller は既存の
GameController のコントローラーを押し出さず、BLE がすでにそのプレイヤーを所有している場合、新しい GameController のコントローラーは待機します。

`--control-fifo` のテストコマンド: `pad on` (コントローラーのないパッド。`--input-selftest` が使います)、
`pad off`、`pad test` (A + 左スティック) — それぞれプレイヤー番号を取ります (`pad on 2`。省略時は 1) —
そして `pad state` (ゲストのパッド、最後の振動レベル、ゲストが HID デバイスを受け付けるかどうか、
接続中の DualSense と Steam Controller、パススルーした入力レポート)。

## FX Steam Launcher.app

`host/launcher/build.sh` (および `./build.sh host`) は、`work/out/steamac-vm` に加えて `work/out/FX Steam Launcher.app`
をビルドします (`host/launcher/bundle.sh`): `es.fxgam.steamac`、`@rpath` 経由で `Contents/Frameworks` に置かれるライブラリ
(libkrun、libvirglrenderer、libMoltenVK、libepoxy)、そして
`Contents/Resources` には gvproxy、`Image` カーネル、`initramfs.cpio.gz`、`steamac-layer.img`、
desync、ディスク作成用の Valve の CA が入ります (ライセンスは `Resources/licenses` にあります)。アイコン:
`host/launcher/AppIcon.icon` (Icon Composer のドキュメント) は `actool` によって `Assets.car` にコンパイルされ
(macOS 26 では Liquid Glass、macOS 15 向けには作成済みのレンダリング)、フォールバックとして `AppIcon.icns` があります。
署名は hypervisor + disable-library-validation の entitlements 付きのアドホック署名です。アプリは
`/Applications` に移動できます。

Finder から (引数なしで) 起動すると、バンドル内のカーネル、initramfs、レイヤーと、
Settings → Advanced → Disk image で指定した SteamOS ディスクを使います。デフォルトは
`~/Library/Application Support/es.fxgam.steamac/steamos.img` で、それ以外の場合はリポジトリの
`work/out/steamos.img` (バンドルの隣、またはビルドした場所) を使います。ディスクがない場合は、
初回起動ウィンドウが **Create New Disk…** (次のセクションを参照) または **Use Existing Disk…** を提示します
(イメージはその場で使われ、コピーされることはありません。`scripts/build-image.sh` でもビルドできます)。ディスクは
このレイアウトのパーティションを持つ raw SteamOS GPT ディスクでなければなりません: Steam Deck のリカバリーアーカイブや macOS 版 Steam の
インストーラーは選択時に拒否され、保存済みのディスクがそうでない場合は起動前に拒否されます
(STEAMAC-7Y/7Z)。それでもゲストの initramfs が失敗した場合 (`steamac-init: FATAL …`)、ウィンドウは
3% のまま止まるのではなく失敗を表示します。ランチャーが開けない、またはロックできないディスク (権限、リムーバブルボリュームへの
アクセス) については、Finder → Get Info → Sharing & Permissions と Privacy & Security を案内し、ログに記録します。
クラッシュレポートとしては送信しません (STEAMAC-15)。この
モードでは、ゲストのコンソールとランチャーのログは
`~/Library/Logs/es.fxgam.steamac/steamac-vm.log` に書き込まれ、SIGUSR1 のフレームダンプもそこに出力されます。`./run.sh`
と `work/out/steamac-vm` はこれまでどおり動作します (ウィンドウの設定はフラグで上書きしない限りこれらにも
適用されます)。

イメージが外部ディスク上にある場合、Finder からの初回起動時に macOS が「FX Steam Launcher
would like to access files on a removable volume」と尋ねます — 許可してください (応答するまで VM はディスクが開くのを
待ちます)。署名はアドホックなので、バンドルを再ビルドした後に macOS が再び尋ねることがあります。

1 つのディスクイメージは一度に 1 つの VM でしか使えません: VM プロセスは終了するまで書き込み可能なディスクに
排他ロック (`flock`) を保持し、2 つ目のランチャー (アプリの別のコピー、たとえば
`/Applications` の隣にあるソースからのビルド、または `steamac-vm`) は、同じファイルシステムを二重にマウントする代わりに
「SteamOS is already running」と表示して起動を拒否します (二重マウントは `/home` と `/var` を破損させます)。ロックは
ランチャーが強制終了されても、ゲストのシャットダウン中は残ります。ロック導入前にビルドされたランチャーは
これをチェックしません。

起動時に `/home` にまだエラーがある場合 (書き込み中に強制終了された VM、またはロック導入前の 2 つのランチャーで
使われたディスク)、SteamOS は「Starting SteamOS services…」で止まる代わりにそれを修復します: ランチャーは
カーネルのコマンドラインに `fsck.repair=yes` を追加するため、systemd-fsck は安全な preen 修正だけでなく、
すべてに yes と答えて e2fsck を実行します。e2fsck が元に戻せなかったファイルは `/home/lost+found` に置かれます。

## アンインストール

ランチャーは Mac のドライブをパーティション分割しません: SteamOS、そのゲームとセーブデータは 1 つのディスクイメージ
ファイルに入っています。すべてを削除するには:

1. FX Steam Launcher を終了します (SteamOS も一緒にシャットダウンします)。
2. Settings → Advanced → Disk image に表示されているディスクイメージを削除します (デフォルトは
   `~/Library/Application Support/es.fxgam.steamac/steamos.img` で、手順 4 で削除されます)。別の
   ボリューム上のディスクでは、その隣に `steamos.provision.img` (初回起動が完了するまで) とダウンロードキャッシュ
   `steamos.img.cache` が残っていることもあります。
3. `FX Steam Launcher.app` を Applications からゴミ箱に移動します。
4. ターミナルで、ランチャーのデータ (ディスク、ゲーム統計、Moonlight のペアリング、ダウンロードとクラッシュレポートのキャッシュ、
   ログ、保存された問題レポート) と設定を削除します:

   ```
   rm -rf ~/Library/Application\ Support/es.fxgam.steamac ~/Library/Caches/es.fxgam.steamac \
          ~/Library/Logs/es.fxgam.steamac ~/Library/HTTPStorages/es.fxgam.steamac
   defaults delete es.fxgam.steamac
   ```
5. 必要に応じて、キーチェーンアクセスで「FX Steam Launcher: SteamOS user steamos」のパスワードを削除します
   (サービス `es.fxgam.steamac.guest-password`、ディスクごとに 1 つ)。

## 言語

ランチャーのインターフェースは英語、ロシア語、簡体字中国語に対応しており、macOS の言語に従います
(System Settings → General → Language & Region、Applications でアプリごとにも設定可能)。ログ、コマンドラインの
出力、クラッシュレポート、問題レポートは英語のままです。ゲストエージェントの固定された Steam のステージテキスト
("Checking for Steam updates" など) は翻訳されて表示されます (`BootProgress.localizedGuestText`)。その他の
ゲストのテキスト (systemd の行、SteamOS 自体) はランチャーでは翻訳されません。

文字列は String Catalog にあります: `host/launcher/Localizable.xcstrings` (キーは英語のテキスト) と
`host/launcher/InfoPlist.xcstrings` (権限のプロンプト) です。コードでは、SwiftUI のリテラル (`Text("…")`、
`Button("…")`) は自動的にローカライズされます。それ以外のすべての UI 文字列は
`String(localized: "… \(value) …")` として書きます — キーごとに 1 文で、引数は埋め込み、断片から組み立てることは
しません — そしてログや CLI 向けのテキストは英語のプレーンな文字列のままにします。`host/launcher/build.sh`
は `-emit-localized-strings` 付きでコンパイルし、抽出したキーをカタログに同期し (新しいキーは
追加され、削除されたキーは stale としてマークされます — カタログはコードと一緒にコミットしてください)、未翻訳のキーと
フォーマット引数の不一致を表示し (`host/launcher/l10n.py check`)、カタログを
`work/out/steamac-vm` の隣とアプリの `Contents/Resources` 内の `<lang>.lproj` にコンパイルします。`dist.sh` は
未完成の言語を含むリリースを拒否します。Xcode 以外で翻訳する場合: `host/launcher/l10n.py export ru
todo.json` で不足しているものを一覧し、`host/launcher/l10n.py import ru done.json` で
`{"key": "text"}` または `{"key": {"plural": {"one": …, "few": …, "many": …, "other": …}}}` を追加します。Xcode で
カタログを直接開くこともできます。システムの言語を変えずに言語を確認するには:
`work/out/steamac-vm -AppleLanguages '(ru)' …`。

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

## Steam クライアント

SteamOS がどの Steam クライアントを起動するかはランチャーで選択します: 初回起動ウィンドウ、
**Create SteamOS Disk** ウィンドウ、**Settings → Advanced → Steam client** で選べます (次回起動時に適用、
「Restart VM to apply」)。1 回の起動だけなら `--steam-client frame|deck|deckbeta` を使います。ランチャーは
起動のたびにカーネルの cmdline で `steamac.steam_client=…` として選択内容を渡し、
レイヤー内の `/usr/lib/steamac/steam-client` が Steam の起動のたびにそれを読み取ります。Steam のサービスは
SteamOS 標準のサービス (`steam.service`) のままで、レイヤーはそれに
`steam.service.d/50-steamac.conf` のドロップインを追加するだけです。起動前に、`steam-client` は標準の
`/usr/share/deckard/RUNSTEAM.sh` を `~/.local/share/Steam/` にコピーします — アカウントが記憶されている Frame クライアントでは
変更せず、`deck`/ブランチ/サインインのモードではコピーから
`-deckard` と `-vrgamepadui` の引数を含む行だけを削除します。Valve のファイルは
レイヤーに含まれていません。

| オプション | 内容 | 長所と短所 |
|---|---|---|
| **Steam Deck client** (`deck`、デフォルト) | 公開されている ARM64 版 Steam Deck クライアント、`steamdeck_stable` ブランチ (公開されている `steam_client_linuxarm64` と同じビルド。ARM 向けには公式に発表されていません) | 画面上の QR コードによる通常のサインイン。内部ベータではなく公開されたクライアントブランチ。**Proton Experimental (ARM64)** は、x86-64 の **Proton Experimental** とは別の互換性ツールの選択肢です |
| **Steam Deck client (beta)** (`deckbeta`) | `steamdeck_publicbeta` ブランチ | `deck` と同様ですが、ベータ版です |
| **Steam Frame client** (`frame`) | Valve の Steam Frame 向けベータクライアント (`linux_arm64_beta_<hash>`、フラグ `-deckard -vrgamepadui`) — イメージに含まれるもの | イメージに同梱されているクライアント。未発売のデバイス向けの内部ベータ。サインインにはサインインモードを使います (下記) |

オプションを変更すると、次回起動時に Steam は別のクライアントをダウンロードします (最大約 1 GB、
進捗は起動オーバーレイに表示)。Frame に戻す場合、Steam のブートストラッパーは `-deckard` フラグに基づいて
自動的に切り替わります。SteamOS 内で手動で設定した `/etc/steamac/steam-client-branch`
(任意のクライアントブランチ) は、`frame` が選択されている場合 (またはランチャーがパラメーターを渡さない場合
— 古いバージョン、カスタムの `--cmdline`) には引き続き機能します。ランチャーの `deck` / `deckbeta` の選択は
ファイルより優先されます。

## Vulkan ドライバー

Venus の背後で動くホストの Vulkan ドライバーは、**Settings → Advanced → Vulkan driver** で選択します (次回起動時に
適用)。1 回の起動だけなら `--vulkan-driver moltenvk|kosmickrisp` で指定できます。デフォルトは KosmicKrisp で、
Mac とビルドが対応している場合 (macOS 26 以降、macOS 26 以降で作られたビルド) に使われ、それ以外では MoltenVK です。
Settings で選択したドライバーはそのまま維持されます。virglrenderer は
実行時にドライバーを開きます (Vulkan ローダーは使いません)。ランチャーは VM の起動前に `VKR_VULKAN_DRIVER` を
`@rpath/libMoltenVK.dylib` または `@rpath/libvulkan_kosmickrisp.dylib` に設定します。起動時の
オーバーレイにはドライバー (“Venus → KosmicKrisp”) が表示され、クラッシュレポートには `vulkan_driver` と
ドライバーのパッチリビジョンが含まれます。

Metal の初期化前に、ランチャーはランタイムコンパイラーのモジュールキャッシュ
(`DARWIN_USER_CACHE_DIR/<bundle id>/com.apple.metalfe`。既存のハッシュディレクトリと
`.pcm` ファイルを含む) に書き込めることを確認します。権限、ACL、変更不可のファイルフラグによって書き込めない場合、ランチャーは
失敗したパスをログに記録し、Metal を `~/Library/Caches/es.fxgam.steamac/metal-compiler` にリダイレクトします。
古いキャッシュの削除や権限の変更は行いません。これには Metal のオプションのキャッシュパス
SPI を使います。上書きが利用できない場合や置き換え先も書き込めない場合は、そのことがログに記録され、
シェーダーのコンパイルエラーは引き続き報告できます。`work/out/steamac-vm --selftest-metal-cache` は
非公開の変更不可キャッシュで `monolithic_metal.pcm: Operation not permitted` の失敗を再現し、その後
置き換え先で実際の Metal ソースのコンパイルを検証します (VM も Sentry イベントも使いません)。この選択は
Metal の初期化前にのみ行われます。後から書き込めなくなったキャッシュは実行中の
プロセスではリダイレクトできないため、レポートには起動時の判断 (`metal_cache` タグ) と、
失敗した `monolithic_metal.pcm` パスの読み取り専用メタデータが含まれます (STEAMAC-7W)。MoltenVK は、テッセレーションと
ジオメトリシェーダーを組み合わせたパイプラインに対応していません。それらは無効なバッファバインディングでコンパイルされる代わりに
`VK_ERROR_FEATURE_NOT_PRESENT` で失敗します (STEAMAC-83)。

| オプション | 内容 | 長所と短所 |
|---|---|---|
| **KosmicKrisp** — Metal 4 上の Mesa · macOS 26 以降 (`kosmickrisp`、利用可能な環境ではデフォルト) | `host/kosmickrisp/`: Mesa main + オープンな MR (ジオメトリシェーダー !44786、トランスフォームフィードバック !44928、ホストポインターメモリ内のタイルイメージ !44929、デバイスローカルのメモリタイプ !44221、リニアのレンダーターゲット !44782/!44222) + steamac のパッチ (明示的な LINEAR の行ピッチ、LINEAR の入力アタッチメント、DXVK が必要とする `fillModeNonSolid`、8 サンプルの要求を 4 として扱う、vkd3d-proton が必要とするテクセルバッファの単一テクセルアライメントと複数の Metal カウンターヒープにまたがるタイムスタンププール、vkd3d-proton が 12 バイトの構造化バッファをそのように参照する R32G32B32 のユニフォームテクセルバッファ (そうしたビューが The Witcher 3 で VM をクラッシュさせていました、STEAMAC-2Z)、macOS 27 でもすべてのゲストデバイスで共有される 1 つの Metal コンパイラー (そのベータ 1–4 では、デバイスごとのコンパイラーがゲストセッションの開始時にヒープを破損させていました、STEAMAC-31)、要素数ゼロのテクセルバッファビューは null ディスクリプターになり、大きすぎるビューは控えめに公表された上限ではなく、アライメント後の Metal のフォーマットごとの容量 (2^28 テクセル、RGB32 要素あたり 3 つ) に切り詰められます: 無効な幅が Metal に届くことも、非同期の Venus の作成失敗が最初の使用時にゲストを終了させることもありません (Spider-Man、Uncharted、Forza Horizon 6、Dragon's Dogma 2、STEAMAC-3J/3F/3S/3R)、バッファを基にしたテクセルバッファビューはそのバッファのレジデンシーを共有します (約 100 万を超えるビューがレジデンシーセットを使い果たして中断していました、DOOM、Wolfenstein、STEAMAC-3V/3T)、32768 エントリのビジビリティバッファ 1 つを超えるオクルージョンクエリと、プロセスのすべてのゲストデバイスで共有されるカウンターヒープ上のタイムスタンププール (Metal ではプロセスあたり 32 個まで) により、Dota 2 / Counter-Strike 2 のクエリプールの作成が失敗しなくなりました、レンダーエンコーダー外のタイムスタンプ書き込みは resolve をまとめ、16384 回の書き込みごとに記録を分割することで、Metal 4 のコマンドバッファ容量の失敗を回避します (Ratchet & Clank: Rift Apart、#45。131072 を超える書き込みは引き続き 0 を読み取ります)、Metal 4 のプレースメントスパースリソース上のスパースバインディング/レジデンシーと、Apple10 より前でシェーダーによってエミュレートされるサンプラーの min/max リダクションにより、vkd3d-proton は Tiled Resources Tier 2、ひいては D3D12 の機能レベル 12_0 を利用できます、コンパイルプールは予測された plain/minmax プログラムだけをキューに入れ、もう一方は最初の使用時にコンパイルします、depth/stencil の状態はその選択とは独立に作成時に一度だけ構築されるため、バインドで待つことはありません、変換済みのシェーダーキャッシュには `force_robustness` などのコード生成の設定が含まれ、コンパイル済みの Metal オブジェクトは所有権を確認して公開する上限付きの LRU テーブルを使います) | 高速: M1 Max で Stellar Blade Demo が約 29 FPS (MoltenVK では約 18) (画面分割の動画: `docs/media/stellar-blade-moltenvk-vs-kosmickrisp.mp4`)。Steam UI、DXVK のゲーム、Stellar Blade Demo (D3D12、vkd3d-proton) が動作し、初回の実行では M1 Max でシェーダーのコンパイルに約 28 分かかります。macOS 26 以降のみ。ビルドホストが macOS 26 以降の場合にのみビルドされ、それ以外では MoltenVK が使われます。既知の不足 (ホストでの再現): ストリップのジオメトリシェーダーを伴うトランスフォームフィードバックとそのオーバーフローカウンター (ドラフト MR)、1 つのレンダーパス内で、マップされていないタイルへの深度書き込みがタイルメモリに残り、そのパスの後続の描画がそれに対してテストされる (Tiled Resources Tier 2 はこのキャッシュを許容しますが、vkd3d-proton の `test_sparse_depth_stencil_rendering` は破棄されることを期待しています)、スパースな 3D テクスチャはなし (Metal の 3D タイルは Vulkan の標準 3D ブロックではありません)、そのため Tiled Resources Tier 3 はなし |
| **MoltenVK** — Metal 3 · macOS 15 以降 (`moltenvk`) | `host/moltenvk/`: UTM のフォーク + steamac のパッチ | 対応するすべての Mac。macOS 15 と KosmicKrisp を含まないビルドではデフォルト (macOS 15 でのソースビルド。リリース版の DMG は 1.7 以降 KosmicKrisp を含みます) |

切り替えると Venus のドライバー識別情報 (パイプラインキャッシュの UUID) が変わるため、Steam とゲームは
シェーダーキャッシュを再構築します。ホストのドライバーが構築できないパイプラインは virglrenderer ではプレースホルダーになります。その描画と
ディスパッチは破棄され、ドライバーが `VK_NULL_HANDLE` を受け取ることはありません。

ホストのドライバーは、そのままでは VM 全体を終了させる Metal のアサーションを引き起こす Vulkan の入力を拒否し、
Vulkan の引数をログに記録します。KosmicKrisp: レイヤー範囲が空または範囲外のイメージビュー、
またはブロックサイズの異なるカラーフォーマット間のイメージビューは `VK_ERROR_FORMAT_NOT_SUPPORTED` で失敗します
(STEAMAC-62/3)。シェーダーが使用するがパイプラインレイアウトにないディスクリプターは 0 を読み取り、書き込みを破棄します
(STEAMAC-6H)。スクラッチバッファを経由するイメージのコピーはミップの内側にとどまり、すべてのボリュームスライスを対象にします
(STEAMAC-5E/5F)。フォーマットのクエリが公表するよりも多くのミップ、レイヤー、深度、サンプルを持つ LINEAR イメージは
`vkCreateImage` で失敗します (STEAMAC-3F/6Y)。キャッシュされたプリコンパイル済みの NIR シェーダーにはデシリアライズ前に
確認される BLAKE3 が付いているため、破損したエントリはクラッシュではなくキャッシュミスになります。
`vkCreateComputePipelines` での STEAMAC-6M/6K/7J/7H/7P のクラッシュには別の原因がありました: Mesa の NIR シリアライザーが
ソースのインデックスを 20 ビットで保存していたため、2^20 個を超えるオブジェクトを持つシェーダーは、ソースが
無関係なオブジェクトを指す状態で戻っていました。現在は大きなインデックスが別のワードに続きます (`host/kosmickrisp/test/nir_object_ids.c`
は KosmicKrisp のビルドで 100 万を超える def を持つシェーダーを往復させます)。128 より深くネストされた選択は
ガード付きの兄弟ブロックとして出力されます。Metal は 256 個を超える括弧でネストされたソースを拒否するためです (
STEAMAC-G のレポート。`sentry-g-brackets.sh` は GPU 上で 320 ケースの分岐するラダーを確認します)。再現性のある
KosmicKrisp のストールについては、macOS のランチャーの起動時に (ゲームの
引数としてではなく) `MESA_KK_DEBUG=syncs,cbs` を設定すると、キューの同期と 1 秒を超えるすべての CPU 待機がトレースされます (STEAMAC-94)。
ソースまたはデスティネーションのバッファが NULL のバッファコピーは、VM プロセスをクラッシュさせる代わりに、1 回の警告とともにスキップされます
(Dota 2、STEAMAC-9S/9T。`host/kosmickrisp/test/copy-buffer-null.py`)。
頂点シェーダーのないグラフィックスパイプラインは、バインド時に VM プロセスをクラッシュさせる代わりに、ステージをログに記録して
作成に失敗します (STEAMAC-AH。`REPRO_CASE=sentry-ah host/moltenvk/repro/run.sh`)。レイヤー数がオーバーフローする
単一レイヤーの 2D イメージのビュー (Zink の `0+65536`) は、GPU コンテキストを終了させる代わりにその 1 レイヤーを
維持します。互換性のないフォーマットのビュー (RGBA8 のイメージ、R8 のビュー) は引き続き拒否され、
ログにはゲストのアプリケーションとビューの引数がすべて記録されます (STEAMAC-G)。コンテキストが持っていない
リソース上の応答ストリームは引き続き致命的なエラーです。virglrenderer は、それがそのコンテキストから切り離されたのか (およびどれだけ
前か)、一度もアタッチされていないのか、共有メモリではないのかをログに記録します (`host/virglrenderer/test/reply-resource.py`、STEAMAC-G)。
致命的なコマンドと失敗したルックアップの行にはゲストのコンテキスト (ID とプロセス名) が記録されるため、終了したコンテキストを
隣接する `destroying context … (explorer.exe)` の行から推測する必要はなくなりました。拒否されたイメージビューについても、
実際のフォーマットの機能とブロックの互換性がログに記録されます (STEAMAC-G: RGBA8 の Zink イメージの R8 ビューで、引き続き拒否されます)。
Metal のエンコーダーを作成する前に、KosmicKrisp はコマンドアロケーター、エンコーダー、アップロードメモリの
上限付きのハイウォーターマークのスナップショットをログに記録します (`REPRO_CASE=command-allocator`)。また、ランチャーは読み込まれている Apple の Metal の計測機能を
記録し (`metal_instrumentation` タグ: `libMetalMetricsInterpose` は HUD がオフでも macOS のフレームペーシングを通じて
読み込まれます)、VM のフットプリントが 30 秒で 8 GiB を超えて増えたときには VM タグ別の内訳を記録します (STEAMAC-AK/AP/AN/AX:
フットプリントが 52 GB から 95 GB に跳ね上がった後に IOGPU のコマンドストレージの割り当てが失敗しました。原因はまだ分かっていません)。
頂点関数がライブラリ内で解決されないレンダーパイプラインは、Metal のプロセス中断
`vertexFunction must not be nil` の代わりに、他のコンパイル失敗と同様に失敗し、名前、ライブラリの関数、プログラムの MSL ハッシュとともにログに記録されます
(STEAMAC-BN/BP。`REPRO_CASE=sentry-bn`)。パスの開始前に破棄されたイメージビューをフレームバッファが参照している
レンダーパスは、Mesa の共通コードが解放済みのビューを参照外しする前に、アタッチメント、フォーマット、フレームバッファとともにログに記録されます
(STEAMAC-BJ/BK、DOOM 2016: `transition_attachment` がビューのイメージを NULL として
読み取りました。誰が破棄したのかはまだ分かっていません。`REPRO_CASE=sentry-bj`)。
macOS での Mesa のバリアのフォールバックにより、`util_queue_finish` がデバイスの破棄 (シェーダーのディスクキャッシュ) でハングしていました。
`host/kosmickrisp/test/util_queue_finish.c` は KosmicKrisp のビルドで実行されます。MoltenVK: Metal がブレンドできない
アタッチメント (R32_UINT) をブレンドするパイプラインは失敗します (STEAMAC-3A)。頂点ステージの補助バッファは
Metal の 31 個のバッファスロットに詰め込まれます (STEAMAC-67)。32 ビットのスペシャライゼーション定数 ID を完全に扱えます
(STEAMAC-6A)。インポートしたホストメモリ内の最適化イメージにはプレースメントヒープが割り当てられるため、
レンダーアタッチメントとして使われる 3D イメージの 2D ビューが存在しないヒープを参照外しすることはなくなりました (STEAMAC-76/77)。失敗したパイプラインは
小さなシェーダー全体、Metal のディスクリプター、ブレンドの状態、フラグメント出力のインデックスをログに記録します (STEAMAC-41/75)。
シェーダーにセカンダリ出力がないアタッチメントのデュアルソースブレンドの係数には 0 が使われます。これは
Vulkan では未定義のままで、Metal は拒否していました (STEAMAC-75)。M1 では、サンプル修飾付きの透視投影は
`get_sample_position(sample_id)` で補間され、Metal にない `llvm.agx2.sample.itrproj`
組み込み関数を回避します (STEAMAC-8J)。SPIRV-Cross は STEAMAC-33/6D/6E/5M/5K/2N/5C/6V の MSL エラーを修正し、
出力をパックする際にデュアルソースブレンド出力の 2 番目のインデックスを維持し (STEAMAC-75)、明示的な
インターフェイスブロックのメンバーの Location を隙間ごと維持し (Location 0 と 2 は `locn0`/`locn1` になっていました)、
オブジェクトシェーダーのペイロードの `locations` を `uint[32][4]` として宣言します (レイアウトは同じ): Apple のコンパイラーは
`uint4 locations[32]` への部分的なストアでクラッシュし、内部エラーまたは中断された XPC 接続として報告されていました
(STEAMAC-41/R)。中断されたコンパイラーサービスのレポートには、ホストのメモリ圧迫とスワップが含まれます (STEAMAC-3X)。
Workgroup (共有) 配列の `vec3` メンバーは、Vulkan のパディング規則がサイズを決めるとおりにパックして保存されるため、
968 要素の `{float; vec3; float}` 配列に必要なのは、Metal の 46464 > 32768 バイトではなく 19360 バイトです (STEAMAC-57)。
同じ Location のフラグメント入力より狭い頂点出力 (float3 → float4) は、入力の幅まで広げられます。
欠けている varying と異なる数値型は引き続き非対応です (STEAMAC-2M/88)。
`rgb9e5` という名前のシェーダー関数は、Metal の `rgb9e5` ピクセル型と衝突しないように名前が変更されます
(STEAMAC-A9)。また、`ClipDistance` だけを書き込むジオメトリ/メッシュステージは、フラグメントシェーダーが読み取る `user(clip0)` のコピーも
書き込みます (STEAMAC-A2)。
Red Dead Redemption 2 の Vulkan レンダラーは、MoltenVK が提供していないにもかかわらず
パイプライン統計のクエリプールを作成します。現在はこれらが作成されて 0 を返し (機能はオフのまま)、失敗して
GPU コンテキストを終了させることはありません。4096 クエリを超えるタイムスタンププールは複数の Metal サンプルバッファを使い、CPU のシャドウを経由してコピーされる
ホストメモリのイメージは実際のテクセル/ブロックの行ピッチを使います (AGX の `bytes_per_row` のアサーション、
STEAMAC-AG/G。`REPRO_CASE=sentry-ag`)。GPU 上で失敗したコマンドバッファは、そのエンコーダーとシェーダーをログに記録します。
Metal がデバイスメモリでのみ提供している、ワークグループ (`shared`) メモリ上の浮動小数点アトミックは、
`atomic_uint` のビットキャストと compare-and-swap ループでエミュレートされます (STEAMAC-AS)。また、ジオメトリ/テッセレーションの頂点
フェッチは、配列型と行列型の頂点入力を、各 Location のフォーマットで 1 Location ずつ読み取ります
(`half2[2]`、STEAMAC-AV。`sentry-as-shared-float.sh`、`sentry-av-array-input.sh`)。
MoltenVK は、Component 修飾付きの個別の頂点出力と対応するフラグメント入力を、幅でリンクされた varying と並べても
区別して維持し、1.9.14 での `locnN` の重複 / 無効な頂点の戻り値型というリグレッションを修正しています
(STEAMAC-87/BB。`REPRO_CASE=sentry-87-components`。通常の宣言とブロックの宣言、幅の両方向、
シリアライズされたパイプラインキャッシュの再利用についてピクセル単位で確認済み)。
`host/moltenvk/repro/sentry-msl.sh` は、再構築された各シェーダーをコンパイルします。wmtr (DXMT) は
ゴミまたは解放済みのオブジェクトハンドルだけを拒否し、コンテキストがなくなったときにゲームが開いたままにしたエンコーダーを終了し (
65,536 個を超える生存オブジェクトでも同様、STEAMAC-70)、頂点関数のないレンダーパイプラインを拒否します
(STEAMAC-6S/6Z)。`wmtr/tests/wmtr_dxmt_test.m` は、出荷される
エグゼキューターを通じて GPU 上で DXMT 自身のコマンドリストを実行します。

KosmicKrisp 上の共有 Vulkan イメージは、非公開のタイルヒープではなく、インポートした共有ページを使います
(#58、Mesa !44929 のための一時的な回避策)。この経路を通るのは、明示的に外部のホストメモリのイメージだけです:
クエリは `OPTIMAL` であっても、1 ミップ、1 レイヤー、シングルサンプルのリニアなバッキングを公表します。
通常のホストから見えるインポートはタイルヒープを維持します。ゲストの Venus と virglrenderer がこの
取り決めを守るのは KosmicKrisp のレンダラーに対してだけで、MoltenVK のレガシータイリングの拒否は変わりません。
`host/moltenvk/repro/shared_image.c` は 2 つのデバイス間の両方向を確認します (ホストの shm のインポート、
Linux での実際のエクスポート/インポートされた Vulkan の fd)。これが検証するのは共有の仕組みであり、MSFS 2024 ではありません:
MoltenVK のホストの `OPTIMAL` のケースは、中断する代わりに既知の行ピッチの制限をスキップします。

**Allow DXMT (Mac の Metal 上の D3D11)、実験的機能。** Settings → Advanced → **Allow DXMT (D3D11 on
the Mac's Metal)** はデフォルトでオフで、次回起動時に適用されます (1 回の起動だけなら `--wmtr-lib PATH` または `--no-wmtr`)。
アプリには `libwmtr_host.dylib` が同梱されており、ゲストのレイヤーには DXMT の
`{d3d11,dxgi,d3d10core,winemetal}.dll` と `winemetal.so` が含まれます。macOS が Metal のドローアブルを提供できない場合 (
たとえばサイズ 0 のレイヤーやドローアブルのタイムアウト)、DXMT は `nil` を表示する代わりにそのフレームをスキップします。これは
Metal によってアサーションとなり、VM を終了させていました (STEAMAC-98)。上限付きのログ行にそれが記録され、レンダリングは
次のドローアブルで続行されます。トグルがオンの場合、ランチャーは
libkrun の wmtr virtio-gpu コンテキスト (パッチ 0018、capset 30) を提供し、`steamac.gfx=dxmt` で起動します。
ゲストの `steam-gfx-path` は、インストール済みのすべての x86-64 の Proton に DXMT を組み込み、Proton の
インストールとアップデートを監視します。トグルをオフにすると `steamac.gfx=vulkan` で起動し、Proton の
元のファイルを復元します。オプションの ARM64EC ペイロードがある場合、`steam-dxmt-arm64ec` は、インストール済みの **Proton 11.0 (ARM64)** から
個別の **SteamMac DXMT (ARM64EC)** 互換ツールを用意します。これは
アップストリームの DXMT の ARM64X DLL と AArch64 ELF の `winemetal.so` を使い、Wine と DXMT をネイティブのまま保ちつつ、
FEX がゲームの x86-64 コードを変換します。この軽量なツールは、インストール済みの Proton へのシンボリックリンク、
約 13 MB の DXMT のファイル、非公開のプレフィックス/修正エントリーで構成され、1.9 GB の完全なコピーではありません。元の
Proton のファイルには手を加えず、アップデートはリンクに直接反映されます。Proton は起動時のパスから
自身のディレクトリを決め、起動のたびに DXVK のセットを
プレフィックスにコピーするため、ツール内のそのパスにある DXMT の `d3d11`/`dxgi`/`d3d10core` が
プレフィックスに届きます。また、Steam のデフォルトに戻したゲームは、次回の起動時に再び DXVK を使います。Wine 自体は
標準のビルドのままです。`winemetal` は `WINEDLLPATH` を通じてツールから提供され、ツールの `run` エントリーポイントが
ゲームのプレフィックスに `winemetal.dll` のエントリーを維持します。ツールは
Proton またはペイロードが変わったときに Steam の起動前に再構築されます。ゲームがツールを使用している間、アップデートは延期されます。存在しない、または非対応の
Proton のソースは管理対象のツールを無効にします。マッピングは、壊れたリンクや
食い違ったリンクをたどる代わりにフォールバックします。SteamPipe の空ディレクトリと読み取り専用の修正は、非公開のプレフィックスの
テンプレートと該当するエントリーに適用されます (他のファイルは権限の修正が必要な場合にのみコピーします)。
標準の Proton の初回起動前でも同様です。
ネストされた `tool/` ディレクトリによって、レガシーな x86-64 のインストーラーはそこに触れません。

Steam の起動前に、`steam-compat-default` は **プロファイルで DXMT を選択したゲームにだけ**、
利用可能であればネイティブのツールへのゲームごとのマッピングを、そうでなければ **Proton 10.0** へのマッピングを、優先度 250 で与えます。
これは DXMT が有効な起動時にのみ行われます。古い x86-64 専用のペイロードは、ARM64EC の Wine では winemetal を
初期化できません。ネイティブの PE の DLL とネイティブの Unix ライブラリの両方が必要です。
対象となるのは、インストール済みの Windows ゲーム (`libraryfolders.vdf` と `appcache/appinfo.vdf`:
タイプが game/demo/application で、oslist に windows を含み linux を含まないもの) で、ユーザーがツールを選択していないものです。
それ以外のゲームは Steam のデフォルトのツール **Proton 11.0 ARM64** を使い続け、Venus 上の DXVK/vkd3d-proton で動作します。
古い一括のマッピングは Steam の初回起動時に削除されます。その後のプロファイルの変更や
新しくインストールしたゲームは、次回の Steam の起動時に適用されます。Steam でのユーザーの編集には手を加えません。
これは単なる DLL の選択ではありません: 一部のゲームは、使用する DLL にかかわらず x86-64 の Proton 10.0 + FEX で
クラッシュします。たとえば Stellar Blade Demo (3564860) は、そこで SEH の再帰を
`virtual_setup_exception stack overflow` で終えますが、Proton 11.0 ARM64 では動作します。
フォールバックの経路では、最初の DXMT のゲームの起動時に Steam が Proton 10.0 (x86-64、Steam Linux Runtime 3.0 の FEX 上) を
ダウンロードし、`steam-gfx-path --watch` がそこに DXMT を組み込みます。Proton Experimental と
Proton 11.0 の **x86-64** ビルドには、x86-64 の Steam Linux Runtime 4.0 (`SteamLinuxRuntime_4`、アプリ 4183110) が必要です。
これらを **Proton Experimental (ARM64)** や **Proton 11.0 (ARM64)** と混同しないでください: こちらは
別の ARM64 ランタイム
(`SteamLinuxRuntime_4-arm64`、アプリ 4185400) を使い、Steam が ARM64 上でインストールします。ゲームの **Properties → Compatibility** で、
名前が明示的に **(ARM64)** で終わるツールを選択してください。Steam Deck の
クライアントでも ARM64 の Experimental を選べるため、そのために Frame のクライアントに切り替える必要はありません。
ワイルドカードのエントリー ("0") は使いません: Steam は優先度の高いワイルドカードを自身のツールにも
適用し、そうして FEX のツールを空にしていました。Allow DXMT をオフにすると、スクリプトのマッピングは削除されます。
Proton 10.0 上の D3D12 は ARM64EC ではなく FEX 上で Wine を実行するため、CPU 時間がかかります。
M1 Max でのエンドツーエンドの測定: Death's Door (Unity、D3D11) は
Proton 10.0 で起動し、レンダラーを "Apple M1 Max" と報告し、エグゼキューターのレイヤーを通じて描画します。
同じ M1 Max での測定 (macOS 27、6 vCPU / 8 GB の VM、120 Hz、KosmicKrisp): Death's Door のタイトル
画面は、デフォルトの Proton 11.0 (ARM64) + DXVK の経路で約 41 FPS、DXMT で約 117 (120 Hz のディスプレイで頭打ち) でした。
d3d11bench は 100 回の描画と 16 回のフルスクリーンパスで 44 / 50 (Proton 10.0 + DXVK) / 100 FPS、2000 回の
描画と 4 回のパスで 133 / 139 / 115 でした (DXMT はディスプレイの 120 Hz で止まり、Vulkan の経路はそれを超えます)。
Steam から起動した 20 秒の実行 3 回の中央値です (DXMT: 2 回の起動にわたる 6 回)。詳細は Web サイトにあります。
ネイティブの ARM64EC ツールと Proton 10.0 + DXMT の比較、M5 Max (macOS 27、12 vCPU / 32 GB の VM、120 Hz、
KosmicKrisp、ARM64EC レイヤー付きの FX Steam Launcher 1.9.13。表示フレームは `WMTR_FRAMES` から、ツールごとに 3 回の
交互の実行)。Death's Door のゲームプレイ (uinput によるスクリプト化されたキーボード入力: 歩行、
ローリング、剣と弓、同じセーブから 26 秒) は、どちらも 120 FPS を維持し、50 ms を超えるフレームはありませんでした。VM の
CPU はネイティブで 330-345%、Proton 10.0 で 406-432% (中央値 342% と 406%、約 16% 少ない)、最悪の
フレームは 17-32 ms と 19-49 ms でした。Super Battle Golf (Unity 6000.3.10f1) は、タイトル画面で
どちらも 120 FPS を維持しました (VM の CPU は 251-279% と 239-254%: タイトル画面では差が出ません)。d3d11bench (x86-64、
Steam から起動、20 秒、中央値) は、100 回の描画と 16 回のパスで 140 / 138 FPS、2000 回の描画と 4 回の
レンダーパスで 270 / 267 でした。ネイティブのツールでは、ゲームの起動が約 1.5 秒早くなります。
Unity はどちらのツールでも非対応の `ID3D11Fence` の作成をログに記録しますが、動作を続けます。
DXMT の winemetal の呼び出しは virtio-gpu を越えて、
**Mac 上の VM プロセス内** のエグゼキューターに届き、エグゼキューターは VM のビューに `CAMetalLayer` を表示します。
そのレイヤーはゲストのコンポジターのカーソルを覆ってしまうため、代わりにランチャーがその上に
ゲーム自身のカーソルを gamescope 互換のサイズで描画します。カーソルの追跡はホストによって制御され、DXMT 専用です: ゲームのフォーカスが
オーバーレイを許可し、実際の wmtr レイヤーがアタッチされて表示されている場合にのみ動作し、
Allow DXMT がオンであるというだけでは動作しません (「仕組み」の「DXMT パスでのカーソル」を参照)。
D3D12 (vkd3d-proton) とネイティブの Vulkan は引き続き Venus 上で動作します。この経路は **D3D11/D3D10 専用** で、D3D9 には対応しません。
DXMT にはまだ互換性の不足があり、**ストリーム出力はありません**。Steam の Vulkan シェーダーキャッシュが Metal にも
有効だと考えず、初回起動時のシェーダーのコンパイルとカクつきを想定してください。

**セキュリティ: これがオンの間、ゲストのプログラムはあなたのユーザー権限で Mac 上のコードを実行できます。**
プロセス内のエグゼキューターと、DXMT の生のホストアドレスのプロトコルは、VM のセキュリティ境界ではありません。
そのため、この経路はデフォルトでオフの実験的機能です。エグゼキューターの障害で VM が停止することもあります。
信頼できるゲストのソフトウェアに対してのみ有効にしてください。

VM の起動前に、ランチャーは `STEAMAC_WMTR=1`、`STEAMAC_WMTR_LIB` (**Executor library**
の上書き。それ以外の場合はアプリの Frameworks または `work/out/host/lib` の `@rpath/libwmtr_host.dylib`)、
`WMTR_PRESENT=overlay` を設定します。オフの場合は 3 つとも解除されます。ライブラリが存在しない/読み込めない場合、または
`wmtr_host_abi_version` がない場合、その起動ではこの経路は無効になります (ログに記録され、Settings では赤色で表示されます。明示的な
`--wmtr-lib` は理由を示して終了します)。libkrun は別の ABI バージョンを拒否します。問題レポート/クラッシュレポートには
`wmtr on|off` が含まれます。

**DXMT のビルド。** Apple シリコンの macOS で、Xcode の Metal ツールチェーン
(`xcodebuild -downloadComponent MetalToolchain`)、Rosetta (x86-64 の Wine のビルドツール用の
`softwareupdate --install-rosetta`)、Homebrew、クライアントのステップ用に `linux/amd64` に対応した Docker/OrbStack をインストールします。
スクリプトは `meson ninja cmake pkgconf zstd` をインストールします。Metal のツールが利用できない場合は、
`DXMT_PREBUILT_METAL` で、同じ固定されたソースからビルドした `dxmt_command.metallib` と
`air_{msad,samplepos,tessellation}.air` を含むディレクトリを指定できます。

```sh
host/dxmt/build.sh fetch llvm native host pe client payload  # default steps, in order
host/dxmt/build.sh pe-arm64ec client-arm64 payload-arm64ec    # add native Proton 11 support
scripts/build-image.sh layer                               # include the guest payload
host/launcher/build.sh                                     # bundle executor + refreshed layer
```

`fetch` は固定された DXMT/DirectX ヘッダーの tarball を検証し、`host/dxmt/patches` を適用します。
`llvm` は静的な LLVM 15.0.7 をビルドします (M2 で約 10 分、固定バージョンが一致する間は再利用されます)。
`native` は `work/build/dxmt-native` に airconv をビルドし、`host` はエグゼキューターをビルド/テストして
`work/out/host/lib/libwmtr_host.dylib` にインストールします。`pe` は 4 つの DLL を `work/out/dxmt-pe` にクロスビルドし、
`client` は Docker で `wmtr/build/x86_64-linux/winemetal.so` をビルド/テストし、`payload` は
ゲストのレイヤーの `/usr/lib/steamac/dxmt/` 用に `work/out/dxmt/{x86_64-windows,x86_64-unix}` を配置します。
各ステップは個別に再実行できます。引数なしの `host/dxmt/build.sh` は、デフォルトの x86-64 のステップを実行します。
3 つのオプションの ARM64EC のステップは、固定された Wine 11.2 のビルドツールとアップストリームの
`build-arm64ec.txt` を使い、ネイティブの ARM64 コンテナーで Unix クライアントをビルド/テストし、
x86-64 のペイロードと並べて `work/out/dxmt/{aarch64-windows,aarch64-unix}` を配置します。ホストのエグゼキューターは
両方のアーキテクチャで共有されます。パッケージングとマッピングの確認:
`python3 scripts/test/steam-dxmt-arm64ec.py`、`python3 scripts/test/steam-compat-default.py`、
`bash scripts/test/steam-gfx-path.sh`。デバイス/リードバックのスモークテストは
`wmtr/tests/d3d11_device_test.c` です。wmtr のエグゼキューターを有効にした起動で、その x86-64 の実行ファイルを
ネイティブの DXMT のツールの下で実行してください。

クレジット: wmtr のリモーティング経路と統合は [StonkGuy](https://github.com/StonkGuy/steamac)、
Metal 上の D3D11/D3D10 は [DXMT by 3Shain (Feifan He)](https://github.com/3Shain/dxmt) によるものです。
`host/dxmt/patches` に取り込んだ修正は、それぞれの作者の名義のままです: David Grinberg、osy、
Holly Hamilton、SteveTanSaMa、hanzpo、Mybono、NerRobDog、时雨、Jakey-Jakey
(詳細はパッチを当てた DXMT の `STEAMAC-README.md` にあります)。

ホストから見えるゲストの割り当てはすべて POSIX の shm で、そのファイルディスクリプターは VM の
プロセスで開いたままになります (マップされた割り当て 1 つあたり約 4 つ)。また、Finder からの起動ではソフトリミットが 256
ディスクリプターで始まります: そうした割り当てが数十を超えると、ゲームは GPU コンテキストを失っていました (STEAMAC-G、Left 4 Dead
2)。VM プロセスは起動時にソフトリミットを `kern.maxfilesperproc` まで引き上げます (“file
descriptors: soft limit 256 → N” としてログに記録されます)。virglrenderer は、失敗した shm やディスクリプターの
操作の errno をログに記録します (“… failed: Too many open files (RLIMIT_NOFILE 256)”)。

VM なしでの確認: `host/kosmickrisp/build.sh` は、配置されたドライバーで `host/moltenvk/probe` と再現テスト
(`REPRO_DRIVER=kosmickrisp host/moltenvk/repro/run.sh <dylib>`、Khronos のローダー経由、テスト
専用) を実行します。`host/virglrenderer/build.sh` は、インストールされた各ドライバーで `venus_check` を実行します。

## サインイン

Steam Frame クライアントのサインイン画面はヘッドセット向けに設計されています: “Tap to confirm” は
Bluetooth LE でスマートフォンとペアリングし、“Scan QR code” は VR ウィンドウを開きます。どちらも VM では動作しません (残るのは
パスワードだけです)。そのため Steam Frame クライアントでは、`config/loginusers.vdf` に
記憶されたアカウントがない間 (新しいディスク、サインアウト、“Remember me” なしでのサインイン)、`steam-client` は
`-deckard`/`-vrgamepadui` なしで Steam を起動します: ブートストラッパーは自身を公開版の
ARM64 Steam Deck クライアント (`steamdeck_stable`) に切り替え、サインイン画面にはパスワードフォームと並んで画面上の QR コード (Steam Mobile
App → Steam Guard → scan) が表示されます。“Remember me” を有効にしてサインインすると、Steam は
一度再起動して Steam Frame クライアントに戻ります (クライアントの切り替えごとに最大 ~1 GB をダウンロードします。
進捗はブートオーバーレイに表示されます)。`client-update.steamstatic.com` にアクセスできない場合、
サインインモードは有効になりません。

サインイン画面で `connection_log.txt` に出る `RecvMsgClientLogOnResponse() : 'Try another CM'` の行は
正常です: CM サーバーはアカウントのサインインがない接続を ~60 秒後に切断し、
クライアントが再接続します。

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

アプリ内アップデート ([アップデートの確認](#アップデートの確認)): `dist.sh` は `SUFeedURL` (`SPARKLE_FEED_URL`、デフォルトは
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
[配布](#配布-dmg) を参照してください。

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

## 問題の報告

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

## 仕組み

| ディレクトリ | 内容 |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + パッチ: depth_clip_enable、YCbCr 配列、null ディスクリプター、zink/DXVK 向けのジオメトリシェーダーのエミュレーション (頂点ストライド、インスタンシング、隣接、ファン、SCALED フォーマット、パックされた頂点フォーマット: 10-10-10-2、RG11B10F、RGB9E5、BGRA8、`gl_in`)、トランスフォームフィードバック (DXVK のストリーム出力) とそのクエリ (SO 統計)、コピー時のクエリ結果の可用性 (Venus 経由の DXVK のオクルージョンクエリ)、バッファアドレスにあるベクトル成分へのアトミック操作 (BDA、vkd3d-proton)、テッセレーション下での成分パックされた頂点出力 (dxil-spirv、Rift Apart)、任意のテクセルをオフセットとするテクセルバッファ (vkd3d-proton)、robustness2 での小さなプッシュディスクリプターバッファへの書き込み、ランタイム配列としての可変個数のディスクリプター配列 (Metal は vkd3d-proton のヒープ配列とプログラムごとに 32 MB を確保していました)、補助バッファの割り当て、Metal リソースの遅延解放、パイプラインキャッシュの UUID へのパッチハッシュの反映、バインド時の `VK_NULL_HANDLE` ディスクリプターセット、カラーアタッチメントの数値型に変換されるフラグメント出力、頂点属性のない頂点シェーダー入力へのゼロ、float フォーマットを通じて読み取る整数の頂点入力、null チェック付きの YCbCr ヘルパーサンプラー、未対応のテクセルバッファフォーマットの拒否。`repro/` のテストは Metal のバリデーション下で実行されます (KosmicKrisp でも: `REPRO_DRIVER=kosmickrisp`)。`bench/run.sh <libdir>…` はビルド間で変更の性能を比較します。`bench/shaders.sh <dump or pack>` は、MoltenVK のシェーダーダンプまたは `bench/pack.py` で作成した 10% のサンプルから、ゲームのシェーダーコンパイル (SPIR-V → MSL、MSL → Metal ライブラリ、パイプラインステート。コールド/ウォーム、スレッド) を計測します |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + 未マージの Mesa MR と steamac のパッチ (「Vulkan ドライバー」を参照)。実行時に LLVM を使わずにビルド (`-Dllvm=disabled`、最初のビルドで得た `mesa_clc`)、`-Db_ndebug=true`。macOS 26+ のみ |
| `host/dxmt/` | 固定バージョンの DXMT + パッチ、静的 LLVM 15、ネイティブの airconv、Windows DLL のクロスビルドとゲストのペイロード。`build.sh fetch llvm native host pe client payload` |
| `wmtr/` | BSD-3-Clause の winemetal リモーティング: ゲストの `winemetal.so` から virtio-gpu を経由して `libwmtr_host.dylib` (DXMT/LLVM をリンク) へ送り、VM ビュー内の CAMetalLayer に表示します |
| `host/libepoxy/` | libepoxy 1.5.10。アップストリームの macOS 向け Meson オプションを使い、Homebrew のボトルをコピーする代わりに macOS 15.0 向けにビルド |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + アップストリームの main とのマージ (venus-protocol 1.1.3) + LINEAR モディファイアー、ホストメモリとしての shm のインポート、失敗したパイプラインのスタブ (virglrenderer で描画を破棄)、拒否されたキャッシュの再作成、shm の遅延アンマップ、スレッドの QoS、実行時に開く Vulkan ドライバー (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.6 + パッチ: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K)、M4 向けの SME マスク、virgl なしの 2D リソース、`SET_SCANOUT_BLOB`、SHM blob のマッピング、Venus のフェンスのシグナリング、virglrenderer のログ、`krun_display_resize` (解像度のその場での変更)、vCPU/GPU スレッドの QoS |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): Metal ウィンドウ (任意で MetalFX 超解像)、起動/シャットダウンの進捗を示す「FX STEAM LAUNCHER」オーバーレイ、ゲストの解像度 = ウィンドウサイズ (Retina 解像度では画面のバッキングスケールを掛けたもの) で DPI は一定 (物理的な画面サイズから得た EDID)、キーボード/マウス/タブレット、GameController.framework からのゲストの Xbox 360 / DualSense / DualShock 4 パッド (振動付き)、または生の HID として素通しする DualSense (`fx.pad`)、gvproxy 経由のネットワーク、ゲストの再起動時の VM の再起動、`--perf-stats` |
| `guest/kernel/` | Linux 7.2.9。すべてを組み込みでビルド、4K ページ、16K の blob ノードアラインメント、FEX 向けの Apple TSO。素通しする DualSense 向けに uhid、hidraw、`hid-playstation` (必要な LED クラスを含む) |
| `guest/mesa/` | 固定バージョンの Mesa から: aarch64 (Proton、gamescope、zink) と x86_64/i386 (FEX のグラフィックスプロバイダー) 向けの Venus ICD。両方で標準のものを置き換える zink GL スタック (libgallium、GLX/EGL/GBM)。`guest/mesa/patches/` にバックポート (Mesa 6abefa51: 頂点レイアウトだけが変わった場合に zink がパイプラインを再構築します。Metal 上の Venus にない `VK_EXT_vertex_input_dynamic_state` がない場合、そうしないと GL ゲームが古い頂点フォーマットで描画してしまいます)。エミュレートされたゲーム向けの x86_64 のフォールトレポーター (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | 起動段階 = 「ブートローダー」: 試行回数カウンター付きの A/B スロット選択、パーツセット、`/etc` と `/usr` のオーバーレイ。ランチャーが作成したディスクの初期プロビジョニング (`steamac.provision=1`: initramfs 内の静的な mkfs.fat、mke2fs、btrfstune)。`steamac.ssh=0` — SSH サーバーなし。ランチャーの設定ペイロード (`steamac.config=1`) — 新しい `steamos` のパスワード。`steamac.tz=` — `/etc/localtime` に Mac のタイムゾーン。Flatpak のサンドボックス向けに `/run/steamac/proc` に手を加えない procfs。`steamac.share=` — 共有フォルダー用の実行時マウントユニット (virtio-fs `macshare`、「共有フォルダー」を参照) |
| `guest/layer/` | `/usr` (読み取り専用の erofs) の上の VM レイヤー: ファイルベースの `splctl`、RAUC 向けの安全なポストインストール、`VARIANT_ID=steamdeck`、DRM 上の gamescope セッション、Desktop Mode (gamescope 内に入れ子にした Plasma)、Frame のハードウェアサービスのマスク、`fx-progress-agent` 進捗エージェント (Rust、`guest/progress-agent/`、`fx.progress` virtio-console ポート) とその root サービス (`fx.clock`、`fx.sleep`、`fx.pad` 上の uinput または uhid のゲームパッド)、短いシャットダウンのタイムアウト、QR コードによる Steam サインインモード (Steam Deck クライアント、記憶されたアカウントがない間)、任意の Steam クライアントブランチ (`/etc/steamac/steam-client-branch`)、Steam のバックグラウンドでのシェーダー処理をデフォルトでオン (`steam-shader-defaults`)、Steam のアイドル時のスクリーンセーバーをデフォルトでオフ (`steam-idle-screensaver`)、固定されたシステム/ユーザーマネージャーの CPU アフィニティマスクのリセット (次回のレイヤー起動時に、サービスが VM で利用可能な vCPU を引き継ぐようにします) |
| `scripts/` | `work/out/steamos.img` のビルド: Valve のパーティションレイアウト (esp、efi-A/B、rootfs-A/B、var-A/B、home) を持つ GPT。`scripts/test/provision-test-disk.sh` — Docker から得たディスクに対するプロビジョニングの開発用テスト。`scripts/test/vkd3d-tiled.sh` — 使い捨ての VM で、D3D12 のタイルリソースと機能レベル (Proton 11.0 の vkd3d-proton のテスト、`d3d12-caps`、`vk-minmax`) を確認する開発用のエンドツーエンドチェック |

### DXMT パスでのカーソル

wmtr では、DXMT はゲームを Mac 上の VM プロセス内の `CAMetalLayer` として表示します。このレイヤーは
ゲストのスキャンアウトの上に合成されるため、ゲストのコンポジターが描画したカーソルは隠れてしまいます。トラッキングは
各ゲストエージェントで**オフ**の状態から始まります。ランチャーは wmtr レイヤーの表示/アタッチ状態が変わるたびに `fx.progress` 経由で
`cursor-track 1|0` を送信し、progress の再接続時やゲストの起動時の
`cursor-ready` ハンドシェイクで現在の状態を再送します。有効化を繰り返すと、カーソルの完全なスナップショットが再送されます。
1 には、ゲームレイヤーを許可するゲームのフォーカスと、実際にアタッチされて表示されている wmtr
`CAMetalLayer` の両方が必要です。そのオーバーレイがない Vulkan と Steam/Desktop ではカーソルのトラッキングは不要です。未知の
ホストコマンドは、新旧のホスト/ゲスト間の互換性のため引き続き無視されます。

有効な間、ゲストエージェント (`guest/progress-agent/src/cursor.rs`) は、アクティブウィンドウの `WM_CLASS` が `steam_app_` で始まる Xwayland ディスプレイを
探します。XFixes のサポートとアクティブなゲームウィンドウが
必要で、ルートウィンドウへのフォールバックはありません。初期のビットマップを
`XFixesGetCursorImage` で取得し、その後は定期的に画像をポーリングするのではなく、XFixes のカーソル変更
イベントで更新します。`QueryPointer` は位置を最大 60 Hz で、
必要な間だけサンプリングします。送信するのは変更点のみです: `cursor 0|1`、
`cursor-image <w> <h> <xhot> <yhot> <base64 BGRA>`、
`cursor-pos <x> <y> <win_w> <win_h>`。位置とサイズは、X のルートではなく、フォーカスされたゲームの X ウィンドウの
クライアントピクセル単位です: ウィンドウモードのゲームでは、ルートがクライアント領域より大きいことがあります。1×1 または
完全に透明なカーソルは非表示になります。Wine はカーソルのないゲームにこれを使います。

ランチャーはこれらを `Progress.swift` で解析し、`Window.swift` を通じて `Presenter.swift` の
`VMView` に転送します。これは `zPosition` 1000 の、`steamac.cursor-overlay` という名前の透明な `CALayer` を所有しています。
このレイヤーは、ゲームレイヤーが表示され、ゲストのカーソルが表示されていてその位置が分かっている
間だけ表示されます。ゲームレイヤーと Metal HUD のポリシーからは除外され、wmtr が
サブレイヤーを削除した場合は再アタッチされます。ビットマップは premultiplied-first の `CGImage` になります。ビューにマッピングする前に、
ビットマップとホットスポットは gamescope の `--cursor-scale-height 720` と同様にスケーリングされます: ゲームウィンドウの高さを H とすると、
目標サイズは `clamp(36 * floor(H / 720), 36, 256)` ピクセルです。これには、ビットマップのいずれかの寸法が目標サイズを超えた場合の
gamescope の正方形への縮小 (ホットスポットの座標は整数に切り捨て) も含まれます。
それ以外の場合、均一なスケールは目標サイズ / ビットマップの高さに基づき、最小で 1 です。
レイヤーは X ウィンドウの位置を、ゲストの画像ではなく、アクティブなリモートゲームレイヤーに表示されているドローアブルの
矩形 (`drawableSize` をレイヤーにアスペクトフィットしたもの。wmtr がそのレイヤーに与えるのと同じジオメトリ) にマッピングします。
そのため、サイズやアスペクト比がゲストのスキャンアウトと異なるゲームレイヤーでも
カーソルはずれません。最終的なビューのスケーリングとアルファブレンドはコンポジターが行います。

表示状態は gamescope の 3 秒のアイドル自動非表示ではなく、**ゲーム自身のカーソル**に従います。既存の
Mac カーソルのポリシーは変わりません: auto モードでは画像の上で非表示になり、キャプチャでは
つかんでいる間は非表示になります。タブレットモードとキャプチャしていない `--mouse capture` では、Mac のカーソルとゲストの
オーバーレイの両方が表示されることがあります。キャプチャ中のマウスルックだけでは、ゲームがまだ表示中と報告しているカーソルは非表示になりません。

MoltenVK は、それ以外は空の SPIR-V ブロックから discard するフラグメントヘルパーも修正しています
(STEAMAC-1Q)。`host/moltenvk/repro/msl_helpers.c` は直接のヘルパーとネストしたヘルパーの両方をチェックします:
discard されたピクセルはクリアのままでストレージバッファーに書き込まず、残ったピクセルは通常どおりレンダリングされます。
Metal の組み込みのオーバーロードを避けるため、ユーザー定義の `log10(float)` ヘルパーの名前を変更します (STEAMAC-1R)。
同じ repro は、パイプラインの作成が成功したかだけでなく、コンピュートヘルパーの結果も読み戻します。

セットの中に `VK_NULL_HANDLE` を含む `vkCmdBindDescriptorSets` (グラフィックスパイプライン
ライブラリでは正当です) で、コマンドバッファーの送信時に VM がクラッシュすることはなくなりました (Counter-Strike 2 は
4 番目を null にして 5 つのセットをバインドします、STEAMAC-25): RADV と同様に、null のセットは何もバインドせず、
ダイナミックオフセットも受け取りません (`repro/invalid_usage.c`)。

カラーアタッチメントと異なる数値型のフラグメント出力 (DXVK による Left 4 Dead 2 のパイプラインは
符号なしの出力を `R32_SINT` アタッチメントに書き込みます、STEAMAC-2C。Vulkan では値は
未定義です) は Metal で失敗し、そのパイプラインの描画はスキップされていました。現在はアタッチメントの
型で宣言され、そのビットが書き込まれます (`repro/frag_output.c`)。

パイプラインに頂点属性がない頂点シェーダー入力 (SCS Truck Simulator のシェーダーは、パイプラインが記述していない
location 1 の `in_var_NORMAL` を読み込みます、STEAMAC-2Y。Vulkan では値は
未定義です) は Metal で失敗し ("missing from the vertex descriptor")、そのパイプラインの描画は
スキップされていました。現在、このような入力はゼロを読み込みます (`repro/vertex_input.c`)。

float の頂点フォーマットから供給される整数の頂点シェーダー入力 (BLUE REFLECTION: Second Light は
`Float3`/`Float4` 属性から `BLENDINDICES1` を `int4` として読み込みます、STEAMAC-3N) は Metal で失敗し ("cannot be
read using MTLAttributeFormatFloat3")、キャラクターが表示されませんでした。現在、属性は
フォーマットと互換性のある型で取得され、そのビットが再解釈されます (`repro/vertex_input.c`)。イミュータブルな YCbCr サンプラーを使うヘルパー関数を通した
ロバストなサンプリングで、コンパイルに失敗することはなくなりました
(`is_null_texture`、STEAMAC-3W。`repro/texture_helpers.c`)。Metal に対応するピクセルフォーマットがないフォーマットのテクセルバッファービューは、
VM プロセスを中断する代わりに `VK_ERROR_FORMAT_NOT_SUPPORTED` で失敗します
(Uncharted、STEAMAC-3Q。`repro/texel_buffer.c`)。Metal の 2^28 テクセルより広いテクセルバッファービューは、
Metal のディスクリプター検証で中断する代わりに `VK_ERROR_OUT_OF_DEVICE_MEMORY` で失敗します (STEAMAC-9E/79)。
失敗したグラフィックスパイプラインは、MSL を伴わないリンクの失敗やコンパイラーのエラーに備えて、各ステージのエントリー
ポイント、シェーダーのハッシュ、リフレクションされたインターフェースをログに記録します。

SteamOS のルートファイルシステムは変更されません: すべての変更は initramfs とレイヤーから来ます。そのため、
Valve の公式アップデート (RAUC + atomupd) はもう一方のスロットにインストールされ、通常どおりロールバックできます。
20260922 → 20260928 のアップデートとロールバックで検証済みです。

レイヤーの Venus ICD は、SteamOS のアップデートで維持される soname だけをリンクします (`guest/mesa/container/verify.sh`
`check_stable_needed`)。libdisplay-info は使用しません。SteamOS 0.6.0 (preview チャンネル、20261020) では
`libdisplay-info.so.1` が `.so.3` に置き換えられました: 1.9.7 の ICD が読み込まれなくなり、gamescope が Vulkan
デバイスを見つけられず、VM は “Starting Steam client” のまま止まっていました (STEAMAC-72)。stable → preview の
20261020 (0.6.0) へのアップデートで検証済みです: アップデートされたスロットで Steam が起動します。

## ステータス

検証済み:

- SteamOS が `graphical.target`、自動ログイン、gamescope セッションまで起動します。ネットワーク (gvproxy 経由の DHCP、
  583 MB の Steam クライアントアップデートのダウンロード)、SSH;
- ゲスト内の Venus: `Virtio-GPU Venus (Apple M4 Max)`、Vulkan 1.4。レンダーテスト (コンピュート + クリア/コピー)
  と KMS 経由のディスプレイ出力がリファレンスとピクセル単位で一致します;
- Proton 11 / DXVK 3.x が必要とする DXVK の機能がすべてゲストで見えます (geometryShader、
  shaderCullDistance、depthClipEnable、robustness2 + nullDescriptor、maintenance5/6 など);
- キーボード、タブレット、マウス、仮想パッドが SteamOS で見えます。DualSense としては、Steam の SDL が
  `PS5 Controller` (type PS5) としてマッピングし、PlayStation のグリフを表示します。パッドは VM の実行中に現れたり、消えたり、
  種類が変わったりします。SDL と Steam の仮想パッドからの振動はランチャーに届きます
  (`rumble 49152 16384` が 1.5 秒、その後 0)。物理コントローラーでの再生はまだ
  検証していません;
- DualSense のパススルー、ゲスト側: 実際の USB レポートディスクリプターを持つ uhid DualSense は、
  ランチャーの代わりとなるものから供給され、`hid-playstation` (ゲームパッド、タッチパッド、モーションセンサー、ヘッドセット
  ジャック、RGB とプレイヤー LED) にバインドします。タッチ位置とタッチパッドのクリックはタッチパッドデバイスに届き、ミュート
  ボタンは Mac 側に戻る出力レポートを通じてミュート LED を切り替え、Steam は HIDAPI ドライバーで
  `/dev/hidraw*` を開きます (`Controller using HIDAPI driver, vid=0x054c, pid=0x0ce6`)。
  Mac 側 (IOHIDManager、USB または Bluetooth 接続の物理 DualSense) はまだ検証していません;
- デスクトップモード: Switch to Desktop、マウス入力付きの Plasma デスクトップ (レターボックス時も)、Return to
  Gaming Mode、デスクトップへの直接起動。Flatpak のサンドボックスが起動します;
- 公式 OTA による A→B アップデートとロールバック;
- zink 経由の GL (Xwayland の glamor、glxgears 約 60 FPS)、Steam UI (ゲームパッド UI、GPU 付きの CEF) が
  VM ウィンドウでレンダリングされます;
- Steam へのサインイン、Proton 11.0-2 (ARM64) と FEX のインストール、DX11 ゲーム (Death's Door) を
  DXVK → Venus → MoltenVK で実行;
- ゲストの解像度は DPI を一定に保ったままウィンドウサイズに追従します。高速なシャットダウン (2–4 秒);
- Heroes of Might and Magic: Olden Era (Unity、DX11) — 7 分間エラーなし (オフラインテスト);
- American Truck Simulator (FEX 上のネイティブ Linux x86_64、zink 経由の OpenGL 4.6 core) — キャリアが読み込まれ、
  KosmicKrisp と MoltenVK で世界がレンダリングされます。

初回のカクつきは Metal のコンパイルによるものです (新しいパイプラインごとに約 50–100 ms)。2 回目以降は
約 1 ms です。突然のシャットダウン後の再起動時には、initramfs が esp/efi の FAT をチェックして修復します。

## 制限事項

- DirectX 12 (vkd3d-proton): KosmicKrisp では feature level 12_0 (tiled resources tier 2: Metal 4 の placement sparse resources 上の sparse binding と
  residency)、MoltenVK では 11_0。どちらも SM 6.0 です (Apple GPU では SM 6.2+ はありません:
  vkd3d-proton は FP32 の非正規化数の flush-to-zero と保持の両方を必要としますが、Metal は非正規化数を保持しません)。
  virglrenderer は、各デバイスが報告する SM 6.0 の前提条件と SM 6.2 の非正規化数のプロパティをログに記録します。Age of
  Mythology: Retold は "Shader model too low (Shader_Model_60)" で停止します (STEAMAC-AB/AC/A0)。M5 Max の
  KosmicKrisp では、起動オプション `VKD3D_DISABLE_EXTENSIONS= VKD3D_SHADER_MODEL=6_6 %command%` でこの
  チェックを通過してメニューまで進みました。これは報告されるシェーダーモデルを上書きするだけで、対戦中に終了することがあります。
  1 つのレンダーパス内では、sparse な深度アタッチメントのバインドされていないタイルに書き込まれた深度は、Apple のタイルメモリに残ります。
  Stellar Blade Demo (UE4) は M4 Max で 1280×800、60 FPS で動作します。初回の実行ではシェーダーのコンパイルに数分かかります。
  Proton ARM64 の x86 エミュレーター (FEX) が、20 分後に一度停止させました (保護された .exe 内の DEP チェック)。
- オーディオ: virtio-snd → CoreAudio (デフォルトのデバイス、または設定で選択したもの)。内蔵スピーカーでの
  レイテンシーは約 65 ms です。起動時、再生では出力デバイスに設定されたスピーカー
  レイアウトから最大 12 の PCM チャンネルを公開します。CoreAudio が明示的に識別した場合は、ハイトスピーカー (例: 5.1.2 や 7.1.4) も含みます。
  分類されていない/ディスクリートのレイアウト、または 32 チャンネルを超えるデバイスは、モノラル/ステレオになります。8 チャンネルだけでは
  5.1.2 を意味せず、Dolby Atmos のエンコードはありません。マルチチャンネルのレイアウトでは、`audio-layout` が
  WirePlumber の起動前に VirtIO ALSA の再生マップを読み取り、SteamOS のステレオポリシーを
  対応する Pro Audio 出力に置き換えます (タイマースケジューリング、再生/録音のグループは別々: ホストのデバイスは
  独立したクロックを持つため)。ステレオのホストでは、SteamOS 標準のプロファイルが維持されます。再生は、新しい
  デフォルト出力や取り外された出力にすぐに追従し、1 秒に 1 回レイアウトを再チェックして、物理
  スピーカーにルーティングし、足りないスピーカーはヘッドルームを確保してダウンミックスします。ゲストのチャンネルマップは起動中は固定です
  (virtio-snd/ALSA がキャッシュするため): より多くのチャンネルや新しいレイアウトをゲームに公開するには、VM を再起動してください。
  `STEAMAC_SND_DUMP` はスピーカーのマッピング前のゲスト PCM を記録します。5.1.2 は実機でテストしましたが、7.1.4 は
  自動化されたマッピングテストのみです。マイクはモノラル/ステレオのままで、テストしていません。マイクの
  録音には macOS のデフォルト入力を使います。マイクの権限が拒否された場合、入力デバイスが
  ない場合、または CoreAudio が 200 ms 以内に開始しない場合、録音は VM のサウンド制御キューをブロックする代わりに
  通常のオーディオエラーで失敗します。再生は録音から独立しています (STEAMAC-8N/8P:
  録音の開始が詰まると、ゲストの録音バッファーが未処理のまま残っていました)。録音のログには入力
  デバイスとマイクの権限の状態が含まれます。
- VM をブロックするアンチチートシステムは動作しません。
- `logicOp` は利用できません (MoltenVK フォークのプライベート Metal API はビルドできません)。zink が警告を出します。

## ライセンス

プロジェクトのコードは Apache License 2.0 (`LICENSE`) の下でライセンスされています。© 2026 FX GAMES FZ LLC。例外は
`NOTICE` に記載しています: Linux カーネルのパッチと設定 — GPL-2.0-only、virglrenderer と Mesa の
パッチ — MIT (それらのプロジェクトと同様)、Valve の `deckard-steamvr-session` パッケージから派生した
5 つの gamescope セッションファイル — MIT © Valve Corporation。Valve の CA 証明書と `docs/media` 内の
スクリーンショットはプロジェクトのライセンスの対象外です。ライセンスの全文は `LICENSES/` にあります。

SteamOS はプロジェクトの一部ではなく、プロジェクトと一緒に配布されることもありません: アプリは、ユーザーが Valve のライセンスに同意した後、
Valve のサーバーから署名済みのイメージをダウンロードします (「Docker を使わない SteamOS
ディスクの作成」を参照してください)。

Steam、Steam のロゴ、SteamOS、Steam Deck、Steam Frame は、米国およびその他の国における Valve Corporation の
商標または登録商標です。このプロジェクトは Valve Corporation とは提携しておらず、
Valve Corporation による承認も受けていません。
