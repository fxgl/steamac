# Vulkan ドライバー

[English](../vulkan-drivers.md) · [Русский](../ru/vulkan-drivers.md) · [简体中文](../zh/vulkan-drivers.md) · **日本語**

← [マニュアル](README.md)

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
Allow DXMT がオンであるというだけでは動作しません ([DXMT パスでのカーソル](architecture.md#dxmt-パスでのカーソル)を参照)。
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
パイプラインの作成で問題が起きる場合は、[Fossilize によるパイプラインのキャプチャと再生](../../host/kosmickrisp/FOSSILIZE.md)を参照してください。
