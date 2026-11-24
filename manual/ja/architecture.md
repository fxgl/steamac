# 仕組み

[English](../architecture.md) · [Русский](../ru/architecture.md) · [简体中文](../zh/architecture.md) · **日本語**

← [マニュアル](README.md)

| ディレクトリ | 内容 |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + パッチ: depth_clip_enable、YCbCr 配列、null ディスクリプター、zink/DXVK 向けのジオメトリシェーダーのエミュレーション (頂点ストライド、インスタンシング、隣接、ファン、SCALED フォーマット、パックされた頂点フォーマット: 10-10-10-2、RG11B10F、RGB9E5、BGRA8、`gl_in`)、トランスフォームフィードバック (DXVK のストリーム出力) とそのクエリ (SO 統計)、コピー時のクエリ結果の可用性 (Venus 経由の DXVK のオクルージョンクエリ)、バッファアドレスにあるベクトル成分へのアトミック操作 (BDA、vkd3d-proton)、テッセレーション下での成分パックされた頂点出力 (dxil-spirv、Rift Apart)、任意のテクセルをオフセットとするテクセルバッファ (vkd3d-proton)、robustness2 での小さなプッシュディスクリプターバッファへの書き込み、ランタイム配列としての可変個数のディスクリプター配列 (Metal は vkd3d-proton のヒープ配列とプログラムごとに 32 MB を確保していました)、補助バッファの割り当て、Metal リソースの遅延解放、パイプラインキャッシュの UUID へのパッチハッシュの反映、バインド時の `VK_NULL_HANDLE` ディスクリプターセット、カラーアタッチメントの数値型に変換されるフラグメント出力、頂点属性のない頂点シェーダー入力へのゼロ、float フォーマットを通じて読み取る整数の頂点入力、null チェック付きの YCbCr ヘルパーサンプラー、未対応のテクセルバッファフォーマットの拒否。`repro/` のテストは Metal のバリデーション下で実行されます (KosmicKrisp でも: `REPRO_DRIVER=kosmickrisp`)。`bench/run.sh <libdir>…` はビルド間で変更の性能を比較します。`bench/shaders.sh <dump or pack>` は、MoltenVK のシェーダーダンプまたは `bench/pack.py` で作成した 10% のサンプルから、ゲームのシェーダーコンパイル (SPIR-V → MSL、MSL → Metal ライブラリ、パイプラインステート。コールド/ウォーム、スレッド) を計測します |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + 未マージの Mesa MR と steamac のパッチ ([Vulkan ドライバー](vulkan-drivers.md#vulkan-ドライバー)を参照)。実行時に LLVM を使わずにビルド (`-Dllvm=disabled`、最初のビルドで得た `mesa_clc`)、`-Db_ndebug=true`。macOS 26+ のみ |
| `host/dxmt/` | 固定バージョンの DXMT + パッチ、静的 LLVM 15、ネイティブの airconv、Windows DLL のクロスビルドとゲストのペイロード。`build.sh fetch llvm native host pe client payload` |
| `wmtr/` | BSD-3-Clause の winemetal リモーティング: ゲストの `winemetal.so` から virtio-gpu を経由して `libwmtr_host.dylib` (DXMT/LLVM をリンク) へ送り、VM ビュー内の CAMetalLayer に表示します |
| `host/libepoxy/` | libepoxy 1.5.10。アップストリームの macOS 向け Meson オプションを使い、Homebrew のボトルをコピーする代わりに macOS 15.0 向けにビルド |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + アップストリームの main とのマージ (venus-protocol 1.1.3) + LINEAR モディファイアー、ホストメモリとしての shm のインポート、失敗したパイプラインのスタブ (virglrenderer で描画を破棄)、拒否されたキャッシュの再作成、shm の遅延アンマップ、スレッドの QoS、実行時に開く Vulkan ドライバー (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.8 (`VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K) と M4 向けの SME マスクを内蔵) + パッチ: virgl なしの 2D リソース、`SET_SCANOUT_BLOB`、SHM blob のマッピング、Venus のフェンスのシグナリング、virglrenderer のログ、`krun_display_resize` (解像度のその場での変更)、vCPU/GPU スレッドの QoS |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): Metal ウィンドウ (任意で MetalFX 超解像)、起動/シャットダウンの進捗を示す「FX STEAM LAUNCHER」オーバーレイ、ゲストの解像度 = ウィンドウサイズ (Retina 解像度では画面のバッキングスケールを掛けたもの) で DPI は一定 (物理的な画面サイズから得た EDID)、キーボード/マウス/タブレット、GameController.framework からのゲストの Xbox 360 / DualSense / DualShock 4 パッド (振動付き)、または生の HID として素通しする DualSense (`fx.pad`)、gvproxy 経由のネットワーク、ゲストの再起動時の VM の再起動、`--perf-stats` |
| `guest/kernel/` | Linux 7.2.9。すべてを組み込みでビルド、4K ページ、16K の blob ノードアラインメント、FEX 向けの Apple TSO。素通しする DualSense 向けに uhid、hidraw、`hid-playstation` (必要な LED クラスを含む) |
| `guest/mesa/` | 固定バージョンの Mesa から: aarch64 (Proton、gamescope、zink) と x86_64/i386 (FEX のグラフィックスプロバイダー) 向けの Venus ICD。両方で標準のものを置き換える zink GL スタック (libgallium、GLX/EGL/GBM)。`guest/mesa/patches/` にバックポート (Mesa 6abefa51: 頂点レイアウトだけが変わった場合に zink がパイプラインを再構築します。Metal 上の Venus にない `VK_EXT_vertex_input_dynamic_state` がない場合、そうしないと GL ゲームが古い頂点フォーマットで描画してしまいます)。エミュレートされたゲーム向けの x86_64 のフォールトレポーター (`/usr/lib/steamac/x86_64/fault-report.so`) |
| `guest/initramfs/` | 起動段階 = 「ブートローダー」: 試行回数カウンター付きの A/B スロット選択、パーツセット、`/etc` と `/usr` のオーバーレイ。ランチャーが作成したディスクの初期プロビジョニング (`steamac.provision=1`: initramfs 内の静的な mkfs.fat、mke2fs、btrfstune)。`steamac.ssh=0` — SSH サーバーなし。ランチャーの設定ペイロード (`steamac.config=1`) — 新しい `steamos` のパスワード。`steamac.tz=` — `/etc/localtime` に Mac のタイムゾーン。Flatpak のサンドボックス向けに `/run/steamac/proc` に手を加えない procfs。`steamac.share=` — 共有フォルダー用の実行時マウントユニット (virtio-fs `macshare`、[共有フォルダー](clipboard-and-shared-folder.md#共有フォルダー)を参照) |
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
