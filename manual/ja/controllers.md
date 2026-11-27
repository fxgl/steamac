# コントローラー

[English](../controllers.md) · [Русский](../ru/controllers.md) · [简体中文](../zh/controllers.md) · **日本語**

← [マニュアル](README.md)

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
  360 パッドなしで保持します。BLE のパススルーは他の GameController パッドを抑制しません。
  パススルー中で VM が動作している間、ランチャーはデバイスを排他的に開きます (`SeizeDevice`)。
  GameController と共有して開くとフィーチャーレポート 1 (Steam のコマンドチャネル) が STALL し、
  Steam の再試行でデスクトップモードの入力が 1–2 秒ごとに途切れていました。排他アクセス中は、
  Mac 側でコントローラーのマウスとキーボード (リザードモード) や GameController 入力を使えず、
  他のアプリで開こうとすると排他アクセスエラーになります。VM の一時停止・終了時、パススルーして
  いないとき、または macOS が排他アクセスを拒否したとき (ログに記録) は、共有モードになります。
  VM の一時停止中は HID 入力が破棄されますが、一時停止で排他アクセスが解除されるため、ボタンを押すと
  GameController の代役を通じてスリープ中のゲストを起こせます (SteamOS に Xbox パッドは作成されません);
- Puck 経由の場合 (`28de:1304`): Puck のインターフェース 2–5 がコントローラーの枠で、
  コントローラー自身のレポートディスクリプターを持ちます。SDL と Steam は Puck のコントローラーを USB のインターフェース
  番号でしか扱わず、uhid デバイスにはそれがないため、コントローラーの状態を運ぶ枠は
  有線の Steam Controller (`28de:1302`、USB バス) として SteamOS に渡されます。コントローラーの状態が
  2 秒間ない枠は再び削除され (コントローラーのオフ、別の枠や Bluetooth への移動)、
  Puck の GameController パッドがあれば通常のパッドに戻ります。**デスクトップモード**では
  猶予は 30 秒で、ワイヤレスの状態以外のすべての入力
  レポートが枠を維持します。これにはリザードモードのキーボード/マウスや
  バッテリーのレポートも含まれます。これにより、デスクトップでの使用中も、
  Options でコントローラーを起こした後も、Valve のパススルーが安定します。ワイヤレスの状態はどちらのタイムアウトも延長せず、切断の
  状態はどちらのモードでも枠を直ちに削除します。デスクトップモードに切り替えても、
  ゲームモードの 2 秒のタイムアウトですでに期限切れになった枠は復活しません。稼働中の各枠は
  Bluetooth コントローラーと同様にプレイヤーを確保できます。GameController は枠とパッドの対応を
  公開しないため、ランチャーは接続順に組み合わせ、HID の枠にプレイヤーが割り当てられた場合に
  限って対応する GameController パッドを除外します。パススルー中の枠は USB コントローラーと同じく
  排他的に開き、VM の一時停止中は共有モードに戻ります。macOS が Puck を GameController に公開
  していれば、ボタンでスリープ中のゲストを起こせます。起こすために SteamOS に Xbox パッドを
  作成することはありません。

SteamOS がシャットダウンまたは再起動を通知すると、ランチャーは排他アクセスを解除します。
ゲストのパッドサービスだけが予期せず停止した場合、macOS からはゲスト側のポートの切断が見えないため、
サービスが再び `hello` を送信するか、VM が一時停止または終了するまで、排他アクセスが続くことがあります。

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
パススルー中の Steam Controller のファームウェア更新を SteamOS の Steam から行っても完了しません (Puck 経由と
USB 接続の両方で確認)。VM を起動していないときに Mac の Steam で更新してください。

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
