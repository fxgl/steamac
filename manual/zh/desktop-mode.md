# 桌面模式

[English](../desktop-mode.md) · [Русский](../ru/desktop-mode.md) · **简体中文**

← [手册](README.md)

Steam → 电源 → **切换到桌面**启动 KDE Plasma；桌面的**返回游戏模式**图标回去。在 Steam Frame 映像上该模式是 VR 桌面（`plasma-session.target` 想要
SteamVR，虚拟机中已屏蔽），层将其替换：`plasma-session.target` 与
`steamac-nested-desktop.service` 在同一 gamescope 中把 Plasma 跑成一个 KWin 窗口
（`/usr/lib/steamac/nested-desktop`，如 Valve 的 `steamos-nested-desktop`），按显示尺寸，gamescope
1:1 显示。`gamescope-onready` 等该服务：Plasma 退出即会话结束，SDDM 重新登录。Plasma 有独立运行时目录与 D-Bus 会话总线；层的
`steamosctl` 垫片（`/usr/lib/steamac/desktop-bin`，其 PATH 首位）把返回游戏模式等 SteamOS 命令发往外部会话总线，由 steamos-manager 执行。桌面 Steam 自启动（`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`）保留启动器所选客户端，而非原生 `-deckard`（Frame 客户端），否则每次切换都下载另一客户端。进度代理上报 `focus desktop <w>x<h>`（Plasma 窗口）：启动器保持相对指针，按 gamescope 缩放映射到该窗口；直启桌面模式（`steamos-session-select plasma-persistent`）在桌面就绪时上报 `ready`。

**键盘布局。** 开启设置 > 通用 > **在桌面模式中使用 Mac 的键盘布局**（默认开，立即生效）后，桌面模式使用 Mac 上启用的键盘布局（按输入法菜单顺序），并随 Mac 的输入法切换（地球仪键、Control-空格）。启动器把布局映射为 XKB（`com.apple.keylayout.Russian` → `ru(mac)`、`RussianWin` → `ru(winkeys)`、`German` → `de(mac)` 等；否则仅接受明确无歧义的首选语言白名单，跳过未知输入源；输入法按实际打字布局计）。最多发送四个布局（XKB 限制），始终包含当前布局，在切换及桌面模式获得焦点时经 `fx.progress` 发送 `keyboard-layout <当前索引> <布局(变体)>…`，之后 1.5、4、8 秒再发送（Plasma 启动时可能在 KWin 接受布局后选回第一个布局）。代理运行 `/usr/lib/steamac/desktop-keyboard`（只处理最新请求，不阻塞）：按客户机 XKB 符号文件验证布局和变体，丢弃未知项并重新计算当前索引；若当前布局被丢弃则不切换。与 Mac 时钟格式相同，布局跟随 Mac，直到在 SteamOS 中更改：首次同步会替换已有的自定义布局；之后观察到用户修改 Plasma 布局便永久尊重用户选择。状态保存在 `~/.config/steamac/mac-keyboard.json`；关闭设置会停止同步，不会恢复旧列表。同步期间写入 `kxkbrc`（清空 `DisplayNames`），当文件改变或 KWin 的布局代码不符时发送 `reloadConfig`（`org.kde.keyboard` `/Layouts`），并通过嵌套会话总线选择当前布局（`org.kde.KeyboardLayouts.setLayout`）；`nested_plasma/steamac-session-bus` 不存在或已失效时不做任何操作。地球仪切换后的 macOS 通知常迟到 0.55–0.85 秒，所以仅当此设置开启、桌面模式有焦点且启动器为活动应用时，每 30 ms 轮询当前布局。按键仍是 Mac 的物理按键（evdev 键码），输入什么由布局决定。游戏模式保持其布局。

Flatpak 应用（Discover）跑在 bubblewrap 中，在用户命名空间挂载自有 procfs。内核仅当挂载命名空间中有完全可见的 procfs 才允许，而 initramfs 把合成 `/proc/cmdline` 覆盖了真实文件；因此它还在
`/run/steamac/proc` 挂载一份 untouched procfs（`nosuid,nodev,noexec`）。没有它每个 Flatpak 应用都以 `bwrap: Can't mount
proc on /newroot/proc: Operation not permitted` 退出。

桌面模式通过 `/usr/lib/steamac/desktop-shell` 运行 `plasmashell`：嵌套会话没有 systemd 用户管理器，原有服务的重启策略不起作用，而 Wayland 协议错误会让外壳绕过崩溃处理器直接退出（`_exit`），只留下黑色桌面和 KWin 窗口（STEAMAC-AJ/9P）。外壳异常退出后会被重启，每分钟最多启动三次；正常注销或外壳正常退出不会重启。问题报告包含桌面软件包版本以及外壳与合成器的日志。
