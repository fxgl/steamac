# 剪贴板与共享文件夹

[English](../clipboard-and-shared-folder.md) · [Русский](../ru/clipboard-and-shared-folder.md) · **简体中文**

← [手册](README.md)

## 剪贴板

设置 → 通用 → **与 SteamOS 共享剪贴板**（默认开，立即生效）：Mac 上复制的文本（UTF-8）
与 PNG 图片可粘贴到 SteamOS（Ctrl+V——Steam 文本框、游戏与桌面模式应用），反向亦可；文本上限 1 MiB、单图 16 MiB（超限跳过并记日志）。密码管理器标为隐藏或临时
（`org.nspasteboard.ConcealedType` / `TransientType`）的内容保留在 Mac，除非开启**包含隐藏（密码管理器）内容**。启动器只在应用活跃且虚拟机运行时每 0.5 秒检查粘贴板
`changeCount`，每次激活检查一次——后台、挂起或睡眠时从不检查；SteamOS 来的图片落在 Mac 上为 PNG + TIFF。

传输：virtio-console 端口 `fx.clipboard`，定帧二进制消息（`HELLO` / `STATE` /
带序号 `SET` / `ACK`；`host/launcher/Sources/steamac-vm/Clipboard.swift`、
`guest/progress-agent/src/clipboard.rs`）。客户机中用户服务
`fx-clipboard-agent.service`（`fx-progress-agent clipboard`，游戏会话与桌面模式会话都需要）拥有并监视 gamescope 两个 Xwayland 服务（`:0` Steam、
`:1` 游戏）的 `CLIPBOARD`（XFixes；TARGETS、UTF8_STRING、text/plain;charset=utf-8、
TEXT、STRING、image/png，256 KiB 以上 INCR）：gamescope 自己经接管选区在两者间同步纯文本，但不同步图片与 INCR 级文本。桌面模式还经
`zwlr_data_control_manager_v1`（有则 `ext_data_control_manager_v1`）使用 Plasma 会话的 Wayland 剪贴板；X11 窗口活跃时 KWin 把它桥给 X11 应用。回声按内容抑制：两侧记住上次发送/接管的内容，一次复制只传一次，无论
gamescope、KWin 或 Klipper 重复宣告多少次。显示器出现时已有的选区（如
Klipper 恢复的历史）不发往 Mac；共享内容改为在 Mac 侧提供。
`--control-fifo` 有 `chord KEYCODE ctrl`（如 `chord 9 ctrl` = 客户机中 Ctrl+V）与
`set shareClipboard on|off`。

## 共享文件夹

**设置 → 高级 → 共享文件夹**（下次启动生效）把一个 Mac 文件夹作为标签为 `macshare` 的 virtio-fs 设备提供给
SteamOS，每次启动时挂载到 **SteamOS 中的挂载点**（默认 `/home/steamos/MacShare`）。文件就地读写，不复制：
存放在 Mac 上的游戏以 Mac 磁盘的速度加载，SteamOS 写入的内容立即出现在 Mac 上。默认关闭（未选择文件夹）。
命令行：`--share DIR`、`--share-mount PATH`，`--no-share` 仅本次启动。

选择共享文件夹后，**用作 Steam 库**默认开启（下次启动生效）。SteamOS 会在 Steam 启动前创建
**`<挂载点>/SteamLibrary/steamapps`**，并注册 `<挂载点>/SteamLibrary`，无需在桌面模式使用
无响应的“添加驱动器”对话框。在 Steam 的存储设置和安装位置选择器中，它是名为 **Mac Share** 的
第二个库，而不是需要格式化的 Deck 可移动磁盘。`--share-library` / `--no-share-library` 仅覆盖
本次启动；关闭后不会删除文件，也不会移除已注册的库。

注册对**每个客户机库路径只进行一次**。之后在 Steam 中移除库会被尊重，即使切换到其他共享后再切回来。
标记为 `~/.local/share/Steam/config/steamac-share-library.json`（在 `config.vdf` 旁）；
如需自动重新注册已移除的路径，请先停止 Steam，再从标记中删除该路径。仅更换 Mac 文件夹而保留
相同的客户机挂载路径不会重新注册。

**文件系统：推荐 APFS。** Proton 将 Windows 前缀存入每个库的 `steamapps/compatdata`，这需要
符号链接，而不只是可写的游戏文件。钩子以 `steamos` 身份在实际挂载的共享中尝试创建并读取符号链接，
失败时跳过注册（包括不支持符号链接的 exFAT）。Mac OS Extended/HFS+ 支持符号链接，不会因文件系统
名称被排除。已在虚拟机中检查 APFS virtio-fs 的读写、chmod，以及 Proton 11 ARM64 前缀的
`dosdevices/c:` / `z:` 符号链接。普通不区分大小写的 APFS 在 Linux 中仍不区分大小写：需要仅大小写
不同的文件名的游戏应使用区分大小写的卷或虚拟机内部库。此功能不会把 Mac/Windows Steam 库转换为
Linux 库；请为 SteamOS 使用单独的文件夹。

实现：`steam-share-library` 是 `steam.service` 的非阻塞 `ExecStartPre`，由与 `steamac.share=PATH`
一起传入的 `steamac.share_library=1` 启用。它在修改任何文件前通过 `findmnt -t virtiofs` 检查
**准确的挂载点**。已测试的 Deck 客户端（1792618285）优先读取
`~/.local/share/Steam/steamapps/libraryfolders.vdf`，缺失时回退到 `config/libraryfolders.vdf`，
并将两者重写为相同副本。钩子原子更新主文件，保留已有编号条目（或导入旧文件），只设置 `path` 和
`label`。Steam 自行分配 `contentid`、测量 `totalsize`、填充 `apps`，不写入猜测的 ID 或安装记录。
先前注册的共享缺失时，Steam **保留条目，但记录“Install folder … not mounted”**，共享恢复前不能用作
安装位置。此时钩子不修改列表或标记，也不会在客户机磁盘上创建替代库。请先连接外置卷再启动虚拟机；
如果启动时未连接，请连接后重启。

启动器通过 `krun_add_virtiofs4` 添加设备（`KRUN_SEMANTICS_LINUX_SIMPLIFIED`：客户机在每个文件上看到自己的
uid/gid，因此 `steamos` 用户无需所有权映射即可读写；无 DAX 窗口），并在内核命令行传入
`steamac.share=PATH`。initramfs（“shared folder” 一节）检查路径——`/home/steamos/` 的子目录，
无空组件、`.` 或 `..`，仅 `[A-Za-z0-9/_.-]`——并写入运行时挂载单元
（`/run/systemd/system/<path>.mount`，`What=macshare`、`Type=virtiofs`、`TimeoutSec=15`），由
`multi-user.target` wanted。它依赖并等待 `steamos-create-homedir.service`，在用户会话之前挂载：
新磁盘上必须先让 SteamOS 创建并填充用户主目录，再让 systemd 创建挂载点，否则主目录会属于 root，
且跳过模板复制。`DefaultDependencies=no` 取消在 `local-fs.target` 之前的隐式顺序（主目录创建较晚），
同时保留关机时的正常卸载顺序。共享挂载失败不阻止启动。该单元仅在本次启动期间存在，与运行时单元屏蔽相同。
启动时不存在的文件夹（外置硬盘已拔出、已改名）会记入日志并跳过——启动器不带共享启动；
只有显式的 `--share` 才会拒绝启动。设置中该行以红色显示为未找到。

**安全。** 按 libkrun 的安全模型，virtio-fs 不会把客户机限制在共享目录内：在 macOS 上 lookup 不过滤 `..`，
启动器也未沙箱化。设置了共享后，SteamOS 中的 root（在其中取得 root 的任何东西：游戏、Flatpak、Proton
漏洞）可能读取你的 Mac 用户能读取的任何内容，并写入该用户能写入的位置。仅与你信任的 SteamOS 共享，不需要时
关闭共享。与 SSH 无关。
