# クリップボードと共有フォルダー

[English](../clipboard-and-shared-folder.md) · [Русский](../ru/clipboard-and-shared-folder.md) · [简体中文](../zh/clipboard-and-shared-folder.md) · **日本語**

← [マニュアル](README.md)

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
