# 使用启动器

[English](../using.md) · [Русский](../ru/using.md) · **简体中文**

← [手册](README.md)

## FX Steam Launcher.app

`host/launcher/build.sh`（与 `./build.sh host`）除 `work/out/steamac-vm` 外还构建
`work/out/FX Steam Launcher.app`（`host/launcher/bundle.sh`）：`es.fxgam.steamac`，`Contents/Frameworks` 中的库
（libkrun、libvirglrenderer、libMoltenVK、libepoxy）经 `@rpath`，`Contents/Resources` 中——gvproxy、`Image` 内核、`initramfs.cpio.gz`、`steamac-layer.img`、
desync 与 Valve 磁盘创建 CA（许可证在 `Resources/licenses`）；图标：
`host/launcher/AppIcon.icon`（Icon Composer 文档）由 `actool` 编译为 `Assets.car`
（macOS 26 的 Liquid Glass，macOS 15 用预渲染），外加回退 `AppIcon.icns`；
带 hypervisor + disable-library-validation 权利的 ad-hoc 签名。应用可移到
`/Applications`。

从访达启动（无参数）用包内的内核、initramfs 与层，SteamOS 磁盘取自 设置 → 高级 → 磁盘映像。默认：
`~/Library/Application Support/es.fxgam.steamac/steamos.img`；否则用仓库的
`work/out/steamos.img`（包旁边或构建处）。无磁盘时，首次启动窗口提供**新建磁盘…**（见[无需 Docker 创建 SteamOS 磁盘](building.md#无需-docker-创建-steamos-磁盘)）或**使用已有磁盘…**
（映像就地使用从不复制；`scripts/build-image.sh` 也可构建）。磁盘必须是带本布局分区的 SteamOS 原始 GPT 磁盘：选择 Steam Deck 恢复压缩包或 macOS 版 Steam 安装器时会被拒绝，已保存但不合格的磁盘在启动前即被拒绝（STEAMAC-7Y/7Z）。若客户机 initramfs 仍然失败（`steamac-init: FATAL …`），窗口显示错误而不是停在 3%。启动器无法打开或锁定的磁盘（权限、可移除卷访问）会提示检查 Finder → 显示简介 → 共享与权限以及隐私与安全性，并只记日志，不作为崩溃报告发送（STEAMAC-15）；磁盘所在驱动器报告输入/输出错误时同样处理（重新连接、在“磁盘工具”中运行“急救”、保留映像；STEAMAC-15）。虚拟机一端的 gvproxy 网络套接字在虚拟机启动前即连接（并完成 vfkit 握手）：启动磁盘已满时给出说明并拒绝启动，gvproxy 已退出时报告附带其日志的启动错误，而不是在客户机启用 virtio-net 时让 libkrun 崩溃（STEAMAC-82）。释放 HID 设备时一并注销其输入与移除回调：IOHIDDevice 关闭后仍保留它们，而交给 GameController 又交回的普通控制器会经同一引用再次打开（STEAMAC-CV）。若写入磁盘前整个目标文件夹消失，会给出说明且不发送到 Sentry（STEAMAC-CR）。此模式客户机控制台与启动器日志写入
`~/Library/Logs/es.fxgam.steamac/steamac-vm.log`；SIGUSR1 帧转储亦然。`./run.sh`
与 `work/out/steamac-vm` 照常用（除非被标志覆盖，窗口设置对它们同样有效）。

映像在外接盘上时，首次从访达启动 macOS 会问“FX Steam Launcher
想访问可移动宗卷上的文件”——允许（回应前虚拟机等待磁盘打开）。ad-hoc 签名，重建包后 macOS 可能再问。

一个磁盘映像一次只能被一台虚拟机使用：虚拟机进程退出前持有可写磁盘独占锁
（`flock`），第二个启动器（应用的另一份拷贝，如 `/Applications` 旁的源码构建，或 `steamac-vm`）以“SteamOS 已在运行”拒绝启动，而非两次挂载同一文件系统（那会损坏 `/home` 与 `/var`）。启动器被杀而客户机仍在关机时，锁会存活。加锁之前的启动器不检查。

若启动时 `/home` 仍有错误（虚拟机被杀时正在写，或一块盘被两个无锁旧启动器用过），SteamOS 会修复而非卡在“正在启动 SteamOS 服务…”：启动器在内核命令行加 `fsck.repair=yes`，systemd-fsck 用回答 yes 的 e2fsck 而非仅安全 preen 修复。e2fsck 放不回去的文件进 `/home/lost+found`。

## 卸载

启动器不会给 Mac 的硬盘分区：SteamOS、游戏和存档都在一个磁盘映像文件里。完全删除：

1. 退出 FX Steam Launcher（SteamOS 随之关机）。
2. 删除设置 → 高级 → 磁盘映像中显示的磁盘映像（默认 `~/Library/Application Support/es.fxgam.steamac/steamos.img`，第 4 步会删除）。位于其他宗卷的磁盘旁边还可能留有 `steamos.provision.img`（首次启动完成前）和下载缓存 `steamos.img.cache`。
3. 把“应用程序”中的 `FX Steam Launcher.app` 移到废纸篓。
4. 在终端删除启动器的数据（磁盘、游戏统计、Moonlight 配对、下载与崩溃报告缓存、日志、已保存的问题报告）和设置：

   ```
   rm -rf ~/Library/Application\ Support/es.fxgam.steamac ~/Library/Caches/es.fxgam.steamac \
          ~/Library/Logs/es.fxgam.steamac ~/Library/HTTPStorages/es.fxgam.steamac
   defaults delete es.fxgam.steamac
   ```
5. 可选：在“钥匙串访问”中删除“FX Steam Launcher: SteamOS user steamos”密码（服务 `es.fxgam.steamac.guest-password`，每个磁盘一个）。

## 语言

启动器界面提供英语、俄语和简体中文，跟随 macOS 语言（系统设置 → 通用 → 语言与地区，也可在“应用程序”中为单个应用设置）。日志、命令行输出、崩溃报告与问题报告保持英文。客户机代理发送的固定 Steam 阶段文本（“Checking for Steam updates”等）会显示为译文（`BootProgress.localizedGuestText`）；其他客户机文本（systemd 行、SteamOS 本身）启动器不翻译。

字符串保存在 String Catalog 中：`host/launcher/Localizable.xcstrings`（键为英文原文）与
`host/launcher/InfoPlist.xcstrings`（权限提示）。代码中 SwiftUI 字面量（`Text("…")`、`Button("…")`）自动本地化；其他界面字符串一律写作 `String(localized: "… \(value) …")`——每个键一句完整的话、参数用插值、不拼接片段——而日志与 CLI 文本保持普通英文字符串。`host/launcher/build.sh` 以 `-emit-localized-strings` 编译，把提取的键同步进目录（新键加入、删除的标记为 stale——目录随代码一起提交），列出未翻译的键与格式参数不一致（`host/launcher/l10n.py check`），并把目录编译为 `work/out/steamac-vm` 旁与应用 `Contents/Resources` 中的 `<lang>.lproj`。语言不完整时 `dist.sh` 拒绝发布。不用 Xcode 翻译：`host/launcher/l10n.py export zh-Hans todo.json` 列出缺失项，`host/launcher/l10n.py import zh-Hans done.json` 导入 `{"键": "文本"}`；Xcode 也可直接打开这些目录。不改系统语言而检查某种语言：`work/out/steamac-vm -AppleLanguages '(zh-Hans)' …`。

## Steam 客户端

SteamOS 启动哪个 Steam 客户端由启动器选择：首次启动窗口、**创建 SteamOS 磁盘**窗口与**设置 → 高级 → Steam 客户端**（下次启动时生效，
“重启虚拟机以应用”）；单次启动用 `--steam-client frame|deck|deckbeta`。启动器
每次启动经内核命令行传递所选 `steamac.steam_client=…`；
层中 `/usr/lib/steamac/steam-client` 在每次 Steam 启动时读取。Steam 服务仍是原生 SteamOS 服务（`steam.service`）；层只给它加
`steam.service.d/50-steamac.conf` drop-in。启动前，`steam-client` 把原生
`/usr/share/deckard/RUNSTEAM.sh` 拷贝到 `~/.local/share/Steam/`——Frame 客户端有记住的账号则原样拷贝，`deck`/分支/登录模式下去掉拷贝中含
`-deckard` 与 `-vrgamepadui` 的行。Valve 文件不进层。

| 选项 | 是什么 | 利弊 |
|---|---|---|
| **Steam Deck 客户端**（`deck`，默认） | 公开 ARM64 Steam Deck 客户端，`steamdeck_stable` 分支（与公开 `steam_client_linuxarm64` 同构建；ARM 版未官宣） | 屏幕二维码正常登录（Steam 手机 App → Steam 令牌 → 扫码）外加密码表单；公开客户端分支而非内部测试版；**Proton Experimental (ARM64)** 是单独的兼容性选项，并非 x86-64 **Proton Experimental** |
| **Steam Deck 客户端（测试版）**（`deckbeta`） | `steamdeck_publicbeta` 分支 | 同 `deck`，测试版 |
| **Steam Frame 客户端**（`frame`） | Valve 的 Steam Frame 测试版客户端（`linux_arm64_beta_<hash>`，参数 `-deckard -vrgamepadui`）——如映像自带 | 映像自带客户端；未发售设备的内部测试版；登录走下述登录模式 |

切换选项下次启动下载另一客户端（至多约 1 GB，
启动覆盖层可见进度）；切回 Frame 时 Steam bootstrapper 按 `-deckard` 标志自动切换。SteamOS 内手写
`/etc/steamac/steam-client-branch`（任意客户端分支）选 `frame` 时仍有效（或启动器不传参数时——旧版本、自定 `--cmdline`）；启动器的 `deck` / `deckbeta` 选择优先于该文件。

## 登录

Steam Frame 客户端登录屏为头显设计：“轻触确认”经蓝牙 LE 配对手机，“扫描二维码”打开 VR 窗口——虚拟机中两者皆不可用（只剩密码）。因此 Frame 客户端下，当 `config/loginusers.vdf` 无记住的账号（新磁盘、退出登录、未勾“记住我”登录），`steam-client`
去掉 `-deckard`/`-vrgamepadui` 启动 Steam：bootstrapper 自动切换到公开
ARM64 Steam Deck 客户端（`steamdeck_stable`），登录显示屏幕二维码（Steam 手机 App → Steam 令牌 → 扫码）与密码表单。勾选“记住我”登录后，Steam 重启一次回到 Steam Frame 客户端（每次客户端切换下载至多约 1 GB；
启动覆盖层可见进度）。连不上 `client-update.steamstatic.com` 则不启用登录模式。

登录屏 `connection_log.txt` 中 `RecvMsgClientLogOnResponse() : 'Try another CM'` 属正常：CM 服务器约 60 秒踢掉无账号登录的连接，客户端重连。
