# 挂起与睡眠

[English](../suspend-and-sleep.md) · [Русский](../ru/suspend-and-sleep.md) · **简体中文**

← [手册](README.md)

## 挂起

**方式：** 设置 → 通用 → “关闭窗口时” → **挂起**——之后关闭窗口挂起虚拟机而非关机；或用 **FX Steam Launcher → 挂起**（Ctrl+Cmd+S，
客户机持有键盘时也可用）。`krun_pause`（libkrun 补丁 0016）停止全部 vCPU 与
客户机音频，窗口隐藏，菜单栏出现 ⏸ 图标：“SteamOS 已挂起”、
何时暂停、占用多少内存，**恢复**、**关闭 SteamOS**。挂起的虚拟机不占 CPU（~0%）；Mac 可睡眠。

**恢复：** 点程序坞图标、重新启动应用（访达、`open`、`open -a`）、用菜单栏
图标，或菜单中选**恢复**。窗口回来（全屏状态也在，若之前是），鼠标捕获恢复；“正在恢复…”进度小条持续到首个新客户机帧（客户机 GPU 空闲如静态 Steam 界面时 0.5 秒；至多 2.5 秒）。

**时钟：** 客户机单调时钟看不到暂停（libkrun 平移虚拟计时器，如 QEMU）——sched_ext 调度器与看门狗不触发。恢复后，
`fx-clock-sync.service` 立刻校准墙钟（层中的 root 服务，用同一
`fx-progress-agent clock-sync` 二进制，由 udev 在端口出现时启动）：启动器把时间以 `time <unix_ns>` 写入 virtio 端口 `fx.clock`；服务只调
CLOCK_REALTIME（`clock_adjtime(ADJ_SETOFFSET)`，只向前、且仅当时钟落后超 1 秒）。
之后 timesyncd 自行同步。

**退出：** 挂起期间 Cmd+Q / 程序坞 → 退出会问“SteamOS 已挂起”：**关闭 SteamOS**
（客户机恢复后正常关机）或**取消**（保持挂起）。注销、
重启与关闭 Mac 不提示。

**限制：** 状态只在 FX Steam Launcher 运行期间存于内存——不落盘（客户机内存与宿主 GPU 状态——virglrenderer、MoltenVK、Metal——不序列化）。退出应用、应用崩溃、注销或关闭 Mac 都是普通 SteamOS 关机；未保存的游戏进度丢失。挂起期间客户机内存持续被占用。客户机网络连接（在线游戏、下载）长暂停后可能断开重连。

## SteamOS 睡眠

Steam → 电源 → **睡眠**、Steam 按空闲自动睡眠（设置 → 电源 → “Sleep after”，默认 1 小时）与
客户机中 `systemctl suspend` 都不会让客户机内核真睡（虚拟机中无从唤醒 s2idle——SteamOS 曾因此挂到应用退出）。层替换
`systemd-suspend.service`（及 `systemd-suspend-then-hibernate` /
`systemd-hybrid-sleep` 同理；休眠在 `sleep.conf.d` 中禁用）的 `ExecStart` 为
`fx-progress-agent sleep`：它执行 `system-sleep` 钩子（`pre`），向 virtio 端口 `fx.sleep` 写入
`sleep <action> <token>` 并等待应答。启动器挂起虚拟机（`krun_pause`，同挂起——CPU ~0%，Mac 可睡），窗口保持打开：帧上覆盖“SteamOS 正在睡眠”卡片。点按、按键、手柄按键或程序坞图标唤醒：`krun_resume`，向客户机发送 `wake <token> <unix_ns>`，命令校准墙钟（如 clock-sync），执行 `post` 钩子后退出——logind 发送
PrepareForSleep(false)，Steam 醒来；“正在唤醒…”进度小条持续到首帧。
唤醒客户机的那次点按/按键不传给客户机。

睡眠中关闭窗口遵循“关闭窗口时”：挂起则隐藏窗口（之后恢复一并唤醒），关闭 SteamOS / Cmd+Q 则唤醒客户机，待客户机睡眠任务结束（`awake <token>`；任务进行中 logind 忽略按键）后按一次电源键。无端口时（`--headless`、旧启动器），客户机睡眠直接失败。

`--control-fifo` 测试命令：`close`、`suspend`、`resume`（也可唤醒睡眠客户机）、
`reopen`、`quit`、`wake`（如唤醒 Mac）、`quit-prompt shutdown|cancel|dump PNG`、
`status open|close|dump PNG|item TITLE`。
