# デスクトップモード

[English](../desktop-mode.md) · [Русский](../ru/desktop-mode.md) · [简体中文](../zh/desktop-mode.md) · **日本語**

← [マニュアル](README.md)

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
