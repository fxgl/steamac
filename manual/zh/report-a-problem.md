# 报告问题

[English](../report-a-problem.md) · [Русский](../ru/report-a-problem.md) · **简体中文**

← [手册](README.md)

遇到问题直接从启动器向开发者报告：
**帮助 → 报告问题…**（或应用菜单）、设置 → 通用中**报告问题…**按钮、“SteamOS 无响应…”卡片上**报告…**链接，以及虚拟机非预期退出（崩溃、错误）后出现的
“FX Steam Launcher 意外停止”窗口中的**报告…**按钮。对话框含：
电子邮件（必填，在本 Mac 记住以便开发者回复）、描述（做了什么、期望什么、实际发生什么）与附件复选框：

- **包含启动器日志**（默认勾）——本次会话启动器、libkrun、virglrenderer 与 MoltenVK
  消息（最近约 2 MB，两进程）与 `perf:`/`stall:` 行；路径 `/Users/<name>` → `~`，
  用户名、电脑名、邮箱与 IP 脱敏；
- **包含 SteamOS 日志（系统日志、Steam/Proton 日志）**（默认勾）——本会话客户机控制台（hvc0）与客户机代理收集的 `steamos-logs.tar.gz`：本次启动 systemd journal
  （`journalctl -b`，最近 5000 行，加用户 journal）、`coredumpctl list`/`info`、
  `dmesg`、`systemctl --failed`、`os-release`、`layer-release`、`/proc/cmdline`、`df`/`free`、
  线程 ID/状态/CPU/等待通道与命令名（`threads.txt`，不含命令参数）、Steam
  客户端日志尾（`console_log`、`stderr`、`bootstrap_log`、`compat_log`、`connection_log`、
  `webhelper`、`cef_log`、`shader_log`、`steamui_*`、Steam Input 的 `controller`、`controller_ui` 与
  `cloud_log`）与 Proton 日志（`PROTON_LOG=1` 的 `~/steam-*.log`、
  `compatdata` 中 prefix 的 `version` 与 `config_info`），FEX 工具构建 ID / Steam 清单 /
  配置、可选 FEX 日志、内存限制、内存/IO/CPU 压力（`/proc/pressure/*`）、`/proc/vmstat` 与三次 `vmstat` 采样、
  SteamVR 与串流日志尾部（`vrserver`、`vrcompositor`、`vrmonitor`、`vrwebhelper`、`vrstream`、`streaming_log`，各 256 KiB，IP 地址已脱敏）与 American Truck
  Simulator `game.log.txt` 最近 512 KiB。ATS 模拟器崩溃请将其 Steam 启动选项设为
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%`，复现后报告；
  收集器收录该日志最近 512 KiB。事后移除启动选项。
  大于 1 MiB 的 Proton 日志经脱敏后按启动部分前 1 MiB 加最后 1 MiB 收集，中间省略，
  以免运行时头部信息与首个异常被崩溃处理程序刷屏淹没（STEAMAC-AA）。桌面模式报告记录 `plasmashell`、KWin
  和 Discover 是否运行，以及允许列表中的渲染器标志，不含进程参数或环境变量值（STEAMAC-9P）。
  启动器日志记录游戏模式的启用资格（运行时与磁盘上的 Info.plist 键）、原生全屏状态与经过筛选的
  `gamepolicyd` 消息（STEAMAC-9V）。
  没有 Proton 日志时，归档会提示：要看到 Windows 游戏本身的失败，需设置启动选项 `PROTON_LOG=1 %command%`、复现一次并重新报告。Unity Player 日志与 Easy Anti-Cheat 文本日志从正在运行或最近启动的游戏的 Proton 前缀，以及所有 Steam 库中最近修改的三个前缀中收集（每个前缀最多四个 256 KiB 的日志，不跟随指向前缀之外的链接，不含存档和二进制文件，经过脱敏）；这并不表示游戏或其反作弊可以运行。
  FEX 从 JIT 代码重抛模拟游戏的崩溃，core 堆栈只有匿名 AArch64 地址。要记录 x86_64 代码 fault 位置，创建
  `~/.local/share/Steam/steamapps/compatdata/<appid>/fex-emu/AppConfig/<可执行文件>.json`（ATS：
  `270880/fex-emu/AppConfig/amtrucks.json`），内容为
  `{"Config":{"Env":"LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so"}}`，复现后报告。
  Steam 启动选项做不到：FEX 的 compat tool 会从环境中移除 `LD_PRELOAD`。
  SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT 时该库把 x86_64 RIP、fault 地址、
  寄存器、每帧模块与偏移的回溯与内存映射写入
  `~/.local/state/steamac/fault-report.txt`。文件不超过 256 KiB，报告以
  `fex/fault-report.txt` 收录。之后游戏自家处理器或默认动作照常，崩溃与其 core dump 不变。没有该文件则库永不加载；事后删除它。
  完整崩溃元数据由 root 钩子仅导出给 `steamos`（root 所有，0640 模式）；
  原始 core 保持私密从不附加。`coredump-pending.txt` 标识仍在生成的转储：
  报告不等它们；完成后另发一份报告。命名空间感知堆栈提取在有符号处解析 pressure-vessel 库（FEX JIT 代码可能仍无符号）。Core 处理限制不降低：超大 core 会丢回溯，`Storage=none` 仍写完整临时 core。Steam ID（`[U:1:…]`、
  7656119…、`userdata/<n>` 中的账号 ID）、Steam 账号/昵称与邮箱打包前替换为占位符；`collect-notes.txt` 列出可读内容。经 SSH，同份脱敏归档可用
  `/usr/lib/steamac/fx-progress-agent collect > /tmp/steamos-logs.tar.gz` 获取；
- **包含虚拟机窗口截图**（默认不勾：画面可能显示 Steam 账号名与好友）。

`system-info.txt`（应用与 macOS 版本、Mac 机型、GPU、libkrun/virglrenderer/MoltenVK 构建 UUID、
内核、SteamOS BUILD_ID、层 release、磁盘大小、虚拟机设置、收集备注）与 `settings.txt`
（保存设置与命令行覆盖；SSH 密码存钥匙串从不进报告，游戏标题也不进）始终附加。**查看将发送的内容**组装报告
并在访达打开其目录——所见即所发。

报告发往 Sentry（`sentry.fxgam.es`，同一项目）做 User Feedback：邮箱、描述、本会话最新错误事件链接（如有）与文件附件，一个 envelope 直发 envelope 端口以便看到服务器应答。关闭崩溃报告也能用（显式用户动作：此时 SDK 与崩溃处理器不启动）。附件上限 20 MB（先裁日志旧部，再丢截图与 SteamOS 归档）；HTTP 413 应答则限额减半重发。发送后显示短报告 ID（事件 ID 前 8 字符）。发送失败目录保留在
`~/Library/Logs/es.fxgam.steamac/reports/<date>-<ID>/`（`report.json` 含邮箱与描述加文件）；对话框提供**重试**与**在访达中显示**，目录也可邮件发送。

原理：监管器始终管道两进程 stderr 并写入
`/tmp/steamac-<pid>/launcher.log`（带时间戳，4 MB 轮转）；虚拟机进程把 hvc0
控制台写到旁边的 `console.log`；启动器退出删除该目录。客户机日志经同一 `fx.progress` 端口反向请求：启动器写
`collect-logs <id>`，代理（以会话用户运行，只能读该用户可读）回复 `logs-begin <id> <size>`、`logs <id> <base64>` 行与
`logs-end <id> <sha256>`（或 `logs-failed <id> <reason>`）；启动器组装归档并校验大小与 SHA-256。20 秒无应答或代理未运行（无心跳），报告不带客户机日志发送，在 `system-info.txt` 注明。

测试：`--control-fifo PATH`，命令 `report open`、`report fill EMAIL TEXT…`（事件打
`test=true`）、`report include launcher|steamos|screenshot on|off`、`report preview`、`report send`、
`report retry`、`report dsn DSN|default`、`report dump PNG`、`report close`；`STEAMAC_REPORT_DSN`
覆盖 DSN（失败路径），`STEAMAC_SENTRY_DEBUG=1` 打印服务器应答。崩溃后窗口：`--sentry-test-crash abort` 加 `STEAMAC_REPORT_DUMP=<dir>`（窗口与对话框 PNG，
随后自行关闭；`STEAMAC_REPORT_TEST_SEND=1` 还发送测试报告）。
