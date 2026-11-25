# 崩溃报告、更新与游戏统计

[English](../privacy-and-updates.md) · [Русский](../ru/privacy-and-updates.md) · **简体中文**

← [手册](README.md)

## 崩溃报告（Sentry）

启动器向开发者自己的 Sentry 服务器（`sentry.fxgam.es`，经 SwiftPM 的
sentry-cocoa 9.30.0 SDK）发送崩溃报告与少量错误。
默认开启；设置 → 通用中**发送崩溃报告和诊断信息**复选框、首次启动窗口或创建 SteamOS 磁盘窗口可关闭（“发送内容”链接展示下表）。关闭后
SDK 根本不启动、不联网（已落盘报告保留在原处、不发送）。单次启动：`--no-crash-reports` 或 `STEAMAC_SENTRY=0`。

发送内容：

- 监管器与虚拟机进程崩溃（信号/abort、未处理异常）：原因、线程堆栈、已加载库。含 Metal/MoltenVK 断言、libkrun/virglrenderer
  abort、经 libkrun C API 传出的 Rust panic。虚拟机进程崩溃报告在下次启动虚拟机时发送。未捕获的 Objective-C 异常按其原因（stderr 中首次抛出的消息与堆栈）分组，而不是归入 `CPPExceptionTerminate`（STEAMAC-58）；
- 少量错误（每进程每指纹至多一次，有全局上限；同一指纹至少一天、着色器编译错误 30 天内不重发）：客户机 GPU 上下文 fatal/device lost（vkr “fatal decoder state”、“device lost”）、MoltenVK
  管线编译错误（`[mvk-error] … compile failed`；MoltenVK 若打印 MSL 源码
  （`[mvk-msl] …`：前 40 行与出错前后行）放 extra `msl_source` 而非面包屑；完整的出错着色器经过脱敏后以 `.metal` 文件附加，最大 256 KiB，每个进程最多两个不同的着色器，按内容哈希去重（STEAMAC-AD）；vkr “pipeline … creation failed on host” 只做面包屑）、libkrun 中 Rust panic（`thread … panicked at`）、首次磁盘预配失败（`provision
  failed`）、磁盘创建失败、非预期虚拟机退出（用户未要求关机时的非零退出码或信号）与空闲指示器“SteamOS 无响应…”；
  “SteamOS 无响应”报告附带 `stall_history`：最多 32 个每秒采样的 GPU 命令计数、心跳时长、
  客户机运行时间/负载、进程 CPU 时间和宿主轮询间隔，即使未开启性能统计也会收集（STEAMAC-8）。
  仅代理心跳停止，并不能证明整个客户机或 GPU 已经挂起。GPU 活动、虚拟机内存和宿主线程快照分别有上限；线程状态与 CPU 估算只是证据，不是调用栈，也不能证明 GPU 死锁。历史还记录宿主应用是否激活、关键窗口以及窗口可见/遮挡状态。“仍在工作”只表示客户机心跳仍在，不能证明游戏在推进或在编译着色器。虚拟机退出报告会说明为何没有附上 macOS 崩溃报告（未及时写出、不可读、不完整或属于其他 pid）。
  空闲指示器持续 10 秒时，同样的采样会写入日志一次，即使心跳仍正常，
  因此无需启用性能统计，“报告问题”也可包含游戏卡顿的诊断信息。
  宿主调度停顿（启动器自身数秒未运行）之后，检测器先观察一个新的心跳窗口，不把停顿算作客户机挂起。
- SIGTERM/SIGINT/SIGHUP 退出的虚拟机（注销、`kill`、处理器安装前的 ^C）不是崩溃：只有日志行，无事件、无报告问题窗口。SIGPIPE 也不是（两进程都忽略：输出管道关闭——终端，或监管器被杀后的监管器 stderr 通道——只失败该次写；虚拟机进程转而记到
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` 或丢弃这些行，让客户机继续关完；STEAMAC-10）。SIGKILL 生成
  warning 级 `vm-killed` 事件，“VM process killed (SIGKILL — memory pressure or force quit)”：
  内核是否因内存杀它（jetsam，监管器 kqueue 的 `NOTE_EXIT_DETAIL`）、
  虚拟机内存与退出/峰值时虚拟机进程 footprint、宿主 `vm_stat` 数（free/compressed/wired、
  swap）、`kern.memorystatus_level` 与启动以来内存压力等级历史
  （变化亦写入日志：`memory pressure: …`）。应用菜单强制退出（或再次请求关机）是请求退出，不报告：虚拟机进程以状态 3
  退出，监管器无需 `user-exit` 标记文件即可识别（Mac 磁盘已满时该标记写不进去，STEAMAC-15）。虚拟机进程崩溃时，
  监管器的报告附上 macOS 自己的崩溃报告（`~/Library/Logs/DiagnosticReports/steamac-vm-*.ips`，按 pid 匹配）：
  标题与 `crash_site` 标签中的崩溃位置（报告按其分组），extra `macos_crash_report` 中的异常、Application Specific
  Information 行（堆损坏陷阱时 libmalloc 的消息）及崩溃线程前 16 帧（库名与符号名）；同一摘要也写入会话日志，因此即使关闭崩溃报告，崩溃后的“报告问题”也包含崩溃位置（STEAMAC-BC）；
  内核的内存终止标志与 SIGKILL 来源未知分开报告（没有该标志并不表示强制退出），并给出峰值占用相对虚拟机与 Mac 内存的比例和采样到的最高内存压力，而不只是 macOS 通告过的等级（STEAMAC-S）。
  `memory_history` 增加最多两分钟的退出前虚拟机 footprint 与宿主内存采样（每 10 秒一次）；
  报告时的独立快照标为退出后状态，因为虚拟机内存已释放。GPU 上下文 fatal 与 SIGKILL 报告附加虚拟机进程最近的 GPU/心跳历史，
  以及进程、Metal、Vulkan 分配与共享内存快照；这些计数相互重叠，不能相加。因磁盘被占用而被拒绝的第二个虚拟机以状态 4 退出：只有说明，不上报。
- 每个事件附带启动器 stderr 最近约 200 行做面包屑（`[steamac-vm]`、
  `[mvk-*]`、libkrun/virglrenderer 警告、启动阶段）与标签：版本
  （`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`）、环境与 `build_kind` 标签：
  `release` ——仅带公证的 `dist.sh` 构建（Info.plist `SteamacDistTeamID`，且运行代码签名确为该团队 Developer ID，用 `SecCodeCheckValidity` 检查），
  `source-build` ——其他 `.app`（`bundle.sh`、ad-hoc/重签拷贝、`dist.sh --no-notarize`），
  `development` ——包外 `work/out/steamac-vm`；macOS、Mac 机型、GPU、vCPU/内存、显示模式、libkrun / virglrenderer / MoltenVK 构建 UUID、`MVK_PATCH_REVISION`、内核版本、
  SteamOS BUILD_ID 与层 release（initramfs 行）、焦点游戏 `appid`
  （有焦点期间）与随机安装 ID。

不发送：客户机控制台（hvc0）、用户与电脑名（`/Users/<name>` → `~`，名与主机名脱敏）、IP 地址（`sendDefaultPii=false`，服务器不暴露 IP）、locale/时区、Steam 账号、游戏标题（仅 App ID）或文件。监管器经通道转发两进程 stderr（终端/日志中照常出现），故崩溃虚拟机进程的末尾行它也能看到。

测试：`--sentry-test-event`（监管器与虚拟机进程各发测试事件；虚拟机进程还发送待处理崩溃报告并退出）、`--sentry-test-crash abort|segv|metal|panic|kill|term|shader`
（虚拟机进程崩溃：C 调用中 `abort()`、`memset` 中 `EXC_BAD_ACCESS`、Metal 断言、内核命令行过长致 `krun_start_enter` 中 Rust
panic——`panic` 需要 `--kernel`，必要时加 `--initrd`；`kill`/`term`——虚拟机进程以 SIGKILL（`vm-killed`
报告）或 SIGTERM（无报告无窗口）自杀；`shader`——打印示例 MoltenVK 编译错误
`[mvk-msl]` 与 vkr 行后退出）。这些事件 `environment=development` 且带
`test=true` 标签。`STEAMAC_SENTRY_DEBUG=1` 打印 SDK 调试日志（服务器应答）。

符号：`build.sh` 把 `steamac-vm` 与捆绑库的 dSYM 放入 `work/out/dSYMs`（libkrun、
virglrenderer、MoltenVK 构建无 DWARF——只有符号表）。`dist.sh`
用 `sentry-cli --url https://sentry.fxgam.es debug-files upload --wait` 上传它们与应用附带的每个 Mach-O（可执行文件、Frameworks、
Resources 中的辅助程序；每个都须通过 `sentry-cli debug-files check`），并把 dSYM 保存为 `work/out/dist/FX-Steam-Launcher-<版本>-dSYMs`。
公证构建必须设置 `SENTRY_AUTH_TOKEN`、`SENTRY_ORG`、`SENTRY_PROJECT`（签名前检查；`--no-sentry-upload` 可跳过）：
1.9 发布时未上传，`steamac-vm` 与 libkrun 中的崩溃因此没有符号。

## 更新检查

release 在应用内自行更新（Sparkle）；其他构建检查 GitHub 最新 release 并提供 DMG。两者共用：虚拟机窗口旁的窗口
（屏幕有空间则不压住；不抢焦点——键盘与捕获鼠标留给虚拟机）、应用菜单 **检查更新…** 项（发现版本后显示“有可用更新：X.Y…”带 新 角标），
以及设置 → 通用中的 **启动时检查更新** 复选框（立即生效）。

**应用内更新（release）。** release（`dist.sh` 把 feed 与 EdDSA 公钥写入 Info.plist）使用
[Sparkle](https://sparkle-project.org) 2.10.1（`Contents/Frameworks/Sparkle.framework`，不含 XPC 服务：应用未沙盒化），
以上述窗口取代其自带界面。复选框开启时，至多每 6 小时请求一次 `https://fxgl.github.io/steamac/appcast.xml`，运行期间也会检查。
feed 整体签名，每个更新另有 EdDSA 签名，解包前都用应用内公钥校验（`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction`）；
Sparkle 还要求新应用的代码签名一致。需要更新 macOS（或其他 Mac）的版本不会提供；菜单检查会说明原因。新版本显示说明与按钮
**安装更新**（后台下载——SteamOS 继续运行，**隐藏** 关闭窗口，**取消** 停止下载——随后由 Sparkle 安装器准备）、**跳过此版本**、
**稍后提醒**。已准备好的更新提供 **安装并重新启动**：SteamOS 完全按“关闭 SteamOS”关机（电源键，至多 180 秒，绝不强制退出），
随后 Sparkle 安装器在运行中的进程之外替换应用并重新打开；以及 **退出时安装**（关闭窗口亦然）：启动器退出时安装。
feed 中有从已安装版本出发的增量更新（仅变化文件）时使用增量，否则下载完整 DMG。

Sparkle 运行在虚拟机进程中（唯一运行 NSApplication 的进程）；退出从不经过 AppKit（客户机关机后 libkrun 结束进程），
而客户机重启后监管进程会从包中启动新的虚拟机进程，这会与正在替换它的安装器竞争。因此，更新准备好后虚拟机进程在 run dir
留下 `update` 标记，监管进程不再启动虚拟机；SteamOS 重启（来自 SteamOS 或“重启虚拟机”）改为“安装并重新启动”。
Sparkle 自己的退出请求（在启动器发起的关机之后到来）被忽略，以免变成强制退出；用户第二次退出仍会强制退出。

无法自我替换的副本保留下述 GitHub 检查（日志 `update: in-app updates off (…)`）：源码构建（`bundle.sh`）、开发版启动器、
直接从 DMG 运行或被 Gatekeeper 转移（未移入“应用程序”）的应用，以及只读卷上的副本。

隐私：Sparkle 的请求只发往 `fxgl.github.io`（feed）与 GitHub release 下载，带标准 `User-Agent`（应用与 Sparkle 版本）；
无系统概况、Mac 或用户标识，无 Sentry。Sparkle 的状态（检查时间、跳过的版本）存于应用设置（`SU…` 键）。

**GitHub release 检查（其他构建）。** 应用启动时（每次启动一次而非每次虚拟机重启，且至多 6 小时一次——跨启动累计），启动器后台请求最新 release，不阻塞启动，
地址 `https://api.github.com/repos/fxgl/steamac/releases/latest`（匿名，10 秒超时；排除草稿与预发布），比较其 `vX.Y[.Z]` 标签与自身版本
（`CFBundleShortVersionString`，数字比较：1.3.10 > 1.3.9）。有新版本时，窗口显示“FX Steam Launcher X.Y 已发布 — 当前版本为 …”，
附 release 说明与按钮 **下载**（浏览器打开 release 的 `.dmg`，否则打开 release 页）、**跳过此版本**（启动时不再提示该版本）、
**稍后提醒**（下次检查再提示）。菜单项立即检查——无 6 小时限制且含已跳过版本——
报告“已是最新版本”或错误；启动时网络与 HTTP 错误只记日志
（`update: …`）。开发版启动器 `work/out/steamac-vm` 启动时不检查（菜单可用）；源码构建（`bundle.sh`）会检查。

GitHub 检查的隐私：请求只发 `api.github.com`（GitHub），只带 `User-Agent:
FXSteamLauncher/<version>`（加标准 HTTP 头与上次应答 ETag，以便 GitHub 回“未修改”）；无 Mac 或用户标识、cookie 或 Sentry。检查时间、ETag、应答与跳过版本存于设置（`updateLastCheck`、`updateETag`、`updateCachedBody`、
`updateCachedURL`、`updateSkippedVersion`）。

测试：`STEAMAC_UPDATE_URL` 覆盖 URL（release JSON 或 `/releases` 数组，`http(s)://` 或
`file://`；同时为开发版启动器启用启动检查），`STEAMAC_FAKE_VERSION` 覆盖启动器版本，`STEAMAC_UPDATE_FEED` 覆盖应用内更新的 feed；FIFO `--control-fifo`：`update check|startup|state`、`update press
download|skip|later|ok|releases|cancel|hide|install|quit`（`install` / `quit`：安装并重新启动 / 退出时安装）、`update dump PNG`（窗口与 `-with-vm.png`——与虚拟机窗口同屏）。本地 feed：见[分发](building.md#分发dmg)。

## 游戏统计

哪些游戏能启动、在何种 Mac 上运行多快：由同意共享的玩家提供数据，所有人均可在
<https://fxgl.github.io/steamac/games.html>（`docs/games.html`）查看。

客户机代理在每秒一次的心跳中监视 Steam 的游戏 scope（`app-steam-app<appid>-*.scope`，
即**暂停游戏**冻结的那些 cgroup），报告 `game-start <appid>`、每 5 秒一次的
`game-mem <appid> <anon_kib> <guest_used_kib>`（游戏的匿名内存与客户机已用内存）、
`game-proton <appid> <version>`（前缀中的 `compatdata/<appid>/version`），紧随其后的
`game-gfx <appid> dxmt|vulkan`（实际图形路径），以及 `game-exit <appid>`；每次启动后，某 app id 首次 `game-start` 或获得焦点后会跟随
`game <appid> <name>`。启动器（`GameStats.swift`）为每次游戏运行生成一份报告：
运行时长与持有焦点的时长（未暂停且虚拟机未挂起），是否曾出现窗口以及等待时间（无窗口的运行视为启动失败），
游戏持有焦点时由客户机 scanout-0 刷新间隔得出的帧率（平均值、中位数、1% low、
每分钟超过 50 毫秒的卡顿次数；排除超过 1 秒的间隔；来自 libkrun 的 `present_frame`，
与 `--perf-stats` 报告的刷新相同），游戏 / 客户机内存峰值、Mac 上虚拟机进程的
`phys_footprint` 峰值、分辨率、Proton 版本及结束原因（`exit`、`shutdown`、`session`）。
每份报告附带 Mac 信息（型号、芯片、性能核心数与总核心数、GPU 核心数、内存、macOS）、
虚拟机信息（vCPU、内存、Vulkan 驱动、wmtr、刷新率、SteamOS 构建版本）及启动器版本。
新的会话与评价报告使用 `v:2`，可选字段为 `gfx`（`vulkan` 或 `dxmt`）和 `env`（“单独配置游戏”中
允许的启动选项，不超过 256 个字符）。实际图形路径取自 `game-gfx`；评价使用上次会话的图形路径和启动选项。
服务仍接受 v1（包括之前保存的会话），将其 `gfx`/`env` 存为 NULL。
无效的 v2 赋值返回 HTTP 400；有效赋值按变量名排序，同名时最后一个生效。

每份报告保存在本 Mac（`~/Library/Application Support/es.fxgam.steamac/game-stats.json`，
每款游戏 20 次会话），并列于**设置 → 游戏**。启用**共享游戏统计**前，任何数据都不会离开 Mac：
首款出现窗口的游戏运行后，启动器仅询问一次，询问窗口位于虚拟机窗口旁，不抢走键盘或捕获的鼠标
（**共享** / **不共享**）；设置 → 游戏中的开关可随时更改此选择。开启时，已结束的会话与评价
会发送到统计服务（`POST /v1/sessions`、`POST /v1/ratings`），也包括之前记录的会话；
关闭某款游戏的**共享**复选框后，该游戏不发送任何数据，且其评价会撤回（`"rating": "none"`）。
上传逐一进行；HTTP 400/413 会丢弃报告，其他错误则在 10 分钟后、下次会话结束或下次启动时重试。

隐私：不包含姓名、用户名或计算机名、Steam 账号、文件或任意输入文本（仅共享上述允许的图形启动选项）；
安装 ID 为随机 UUID，仅用于统计不同 Mac 的数量及限流（不是崩溃报告的 ID）；
服务仅将客户端地址用作临时限流键，绝不保存。

页面只公布聚合数据，绝不公布单次会话，并列出每款游戏已测试的芯片。配置按芯片、内存、Vulkan 驱动、
图形路径和启动选项分组（`gfx`/`env`；保留 `wmtr` 以兼容旧版）。旧行的 NULL `gfx` 在 `wmtr=0`
时表示 `vulkan`，在 `wmtr=1` 时仍未知：允许 DXMT 不等于游戏确实使用了它。
**我的 Mac** 筛选器仅保留配置不高于访问者 Mac 的报告（GPU 核心数、内存与性能核心数均不超过给定值；
API 参数为 `max_gpu_cores`、`max_ram_gb`、`max_pcores`）：能在那里运行的游戏，应该也能在这里运行。
启动器中的**打开统计页面**会传入本 Mac 的参数（`?chip=…&gpu=…&ram=…&pcores=…`）
并开启筛选器；页面会记住这些参数。

`GET /v1/games/<appid>` 还返回 `recommended`（没有合格配置时为 `null`）。在同一“我的 Mac”筛选范围内，
跨芯片按 `(driver, gfx, env)` 分组，要求会话与评价合计至少来自两个不同安装；未知图形路径不能获选。
得分 = `(well + 0.5 × issues) / 全部评价`（无评价时为零）；同分先选更高的 `launch_rate`，
再选更低的 `early_exit_rate`，缺失比率排最后，之后按驱动/图形/env 的确定顺序排序。
结果包括驱动、图形路径、启动选项、安装数/会话数、评价、平均 FPS 的中位数及启动成功率。
网站与启动器显示推荐，但绝不自动应用。

服务：`services/game-stats`——使用 D1 数据库的 Cloudflare Worker（严格校验、幂等会话 ID、
每个地址每分钟 30 次 POST、每个安装的每日上限；聚合数据 `GET /v1/games` 与
`GET /v1/games/<appid>` 在 D1 中缓存 5 分钟，因为 Cache API 在 `workers.dev` 上不起作用）。首次部署：

```sh
cd services/game-stats && npm install
npx wrangler login
npx wrangler d1 create steamac-game-stats      # put the printed database_id into wrangler.toml
npx wrangler d1 migrations apply steamac-game-stats --remote
npx wrangler deploy                            # prints https://steamac-game-stats.<account>.workers.dev
```
更新已有部署时，迁移 `0002_profiles.sql` 为会话和评价添加 `gfx`/`env` 并更新分组索引，保留 v1 数据；
`0003_responses.sql` 添加响应缓存表。务必**先**运行 `npx wrangler d1 migrations apply steamac-game-stats --remote`，
**再**运行 `npx wrangler deploy`。

Worker URL 填入 `host/launcher/Info.plist`（`SteamacGameStatsURL`）与 `docs/assets/games.js`
（`API`）。本地运行：`npx wrangler d1 migrations apply steamac-game-stats --local && npx wrangler dev`、
`npm test`。

测试：`STEAMAC_GAME_STATS_URL` 覆盖服务地址（同时为开发版启动器 `work/out/steamac-vm` 启用上传，
否则它不发送任何数据），`STEAMAC_GAME_STATS_FILE` 覆盖本地文件；FIFO `--control-fifo`：
`guest game-start <appid>` 等为跟踪器提供事件，`stats state|flush|ask|dump PNG|reset-question`、
`stats press share|decline`、`settings games`。
