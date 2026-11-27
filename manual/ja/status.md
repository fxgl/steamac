# ステータスと制限事項

[English](../status.md) · [Русский](../ru/status.md) · [简体中文](../zh/status.md) · **日本語**

← [マニュアル](README.md)

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
