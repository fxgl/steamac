# ストリーミングとリモートプレイ

[English](../streaming.md) · [Русский](../ru/streaming.md) · [简体中文](../zh/streaming.md) · **日本語**

← [マニュアル](README.md)

## LAN ネットワークと Steam Remote Play

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
