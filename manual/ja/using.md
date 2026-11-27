# ランチャーの使い方

[English](../using.md) · [Русский](../ru/using.md) · [简体中文](../zh/using.md) · **日本語**

← [マニュアル](README.md)

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
初回起動ウィンドウが **Create New Disk…** ([Docker を使わない SteamOS ディスクの作成](building.md#docker-を使わない-steamos-ディスクの作成)を参照) または **Use Existing Disk…** を提示します
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
