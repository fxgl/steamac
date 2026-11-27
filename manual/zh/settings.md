# 设置

[English](../settings.md) · [Русский](../ru/settings.md) · **简体中文**

← [手册](README.md)

## 设置窗口

**FX Steam Launcher → 设置…**（Cmd+, ——客户机持有键盘时也可用）。每项标注“立即生效”或“下次启动时生效”。
若改了后一组中的任何项，底部出现 **重启虚拟机以应用**：
客户机经电源键正常关机，监管器用新值重新启动虚拟机（**重启虚拟机**菜单项同理）。命令行标志优先于保存值，但仅对当次启动有效：字段旁显示“已被命令行覆盖
（--cpus 6）”。

| 选项卡 | 立即生效 | 下次启动时生效 |
|---|---|---|
| 通用 | 开关机覆盖层；GPU 空闲“仍在工作 — 正在加载或编译着色器…”指示；“当 FX Steam Launcher 在后台时”：**静音**（默认开：`krun_snd_set_volume(…, mute)` 约 150 ms 渐隐，切回窗口恢复音量）与**暂停游戏**（默认关：客户机代理只冻结焦点游戏——`systemctl --user freeze app-steam-app<appid>-*.scope`，cgroup v2；Steam、下载与更新继续；在线游戏可能断线）。代理确认冻结期间（`game-frozen`/`game-thawed`）窗口变暗并显示“游戏已暂停 · 点按以继续”卡片与标题“— 已暂停”；点按窗口恢复游戏且不传给客户机；崩溃报告（`--no-crash-reports`，见[崩溃报告](privacy-and-updates.md#崩溃报告sentry)）；**启动时检查更新**（默认开，见[更新检查](privacy-and-updates.md#更新检查)）；帧统计日志（`--perf-stats`）；**在桌面模式中使用 Mac 的键盘布局**（默认开，见[桌面模式](desktop-mode.md#桌面模式)） | 启动时全屏；**使用 Mac 的时区和时钟格式**（默认开，见[构建与运行](building.md#构建与运行)） |
| 显示 | 客户机跟随窗口大小；窗口右上角 Apple Metal 性能 HUD（Ctrl+Cmd+P，显示菜单）；**MetalFX 超分辨率**（默认关）：窗口像素多于客户机时（Retina 屏 2 倍、缩放或全屏窗口），Apple MetalFX 空间放大把客户机画面放大到窗口像素尺寸，而非线性 / 最近邻缩放；跑在启动器中的客户机帧上，对所有游戏与 Steam UI 有效 | 物理尺寸来源（屏幕自动 / DPI / 毫米——`--dpi`、`--display-mm`），刷新率（`--refresh`），窗口大小（`--display`）：1280 × 800（Steam Deck）到 3840 × 2560 的标准 16:10、16:9、21:9 与 3:2 分辨率（超出显示器的标注“超出当前屏幕尺寸”；窗口照旧缩小），“适应屏幕”（按显示器取最大，每次启动重算）或“自定…”（宽 × 高输入）；**Retina 分辨率**（可选，默认关）：客户机显示器获得屏幕像素密度（窗口点数 × 启动时屏幕 backing scale，若任一边超过 8192 px 则降低缩放倍率），EDID 物理尺寸不变，SteamOS 把 UI 放大到同样尺寸、文字锐利——但游戏要画 4 倍像素，每帧拷贝大 4 倍；更推荐：Retina 分辨率关 + MetalFX 超分辨率（Retina 屏 2 倍放大） |
| 鼠标 | 游戏中自动捕获；游戏列表（名取自 `appmanifest_<appid>.acf`，使用默认/自动/关闭、忘记此游戏） | — |
| 控制器 | 哪个物理控制器（GameController）驱动虚拟手柄（首个已连接或自选），SteamOS 是否获得手柄及呈现为何种（`--no-gamepad`、`--pad`，见[控制器](controllers.md#控制器)），DualSense 是否按本身直通，其余控制器是否成为玩家 2–4，A/B 与 X/Y 互换，摇杆死区，实时输入测试 | — |
| 声音 | 输出设备（系统默认跟随 macOS，或指定 CoreAudio 设备），音量/静音，低（10 毫秒）/普通（20 毫秒）/稳定（60 毫秒）缓冲——经 `krun_snd_set_*`（`dlsym` 查找；旧 libkrun 下字段置灰并说明） | 声音（`--no-sound`） |
| 游戏 | **共享游戏统计**（同意前关闭，见[游戏统计](privacy-and-updates.md#游戏统计)）；已知游戏及已记录会话的游戏：单独配置（图形、Vulkan 驱动、启动选项，见下文）、会话数、游玩时间、上次会话的 FPS / 1% low / 游戏内存 / Vulkan 驱动、可选的个人评价（运行良好 / 可玩但有问题 / 能启动但无法游玩 / 无法启动）与每款游戏的**共享**开关 | 配置可能需要重启 Steam 或虚拟机（见下文） |
| 高级 | — | vCPU（`--cpus`）、内存（`--mem`）、SSH 开关 + 端口（`--ssh-port`、`--no-ssh`）与生成密码、网络（`--no-net`）、磁盘映像（`--disk`）、新建磁盘…、Steam 客户端（`--steam-client`，见[Steam 客户端](using.md#steam-客户端)）、Vulkan 驱动（`--vulkan-driver`，见[Vulkan 驱动](vulkan-drivers.md#vulkan-驱动)）、允许 DXMT（通过 Mac 的 Metal 运行 D3D11），实验性（`--wmtr-lib`、`--no-wmtr`，见[Vulkan 驱动](vulkan-drivers.md#vulkan-驱动)）、共享文件夹 + SteamOS 中的挂载点 + 用作 Steam 库（`--share`、`--share-mount`、`--no-share`、`--share-library`、`--no-share-library`，见[共享文件夹](clipboard-and-shared-folder.md#共享文件夹)） |

开启 **Retina 分辨率** 后，客户机全屏时可使用 5K 和 6K 显示器的完整原生分辨率（默认 Retina
缩放下，Studio Display 为 5120 × 2880，Pro Display XDR 为 6016 × 3384），长边不再受原先的
4094 px 限制。如果之前已开启此选项，GPU 负载可能会上升。

Gamescope 在任何刷新率下都[屏蔽 4096 × 2160 这一特定分辨率](https://github.com/ValveSoftware/gamescope/blob/a962a4dc136369708657605f87057ba3f9991fda/src/Backends/DRMBackend.cpp#L1008-L1026)，
因此 SteamOS 游戏模式在请求该分辨率时会使用 4095 × 2159 作为备用模式。

**虚拟机内存与图形共享 Mac 的内存。** 自动分配的虚拟机内存为物理内存的一半（4–16 GiB）。
每次启动还会为 macOS、其他应用和驱动开销预留至少 3 GiB 或宿主内存的四分之一，
剩余部分作为 GPU 预算（256 MiB–16 GiB，向下取整到 256 MiB）。
16 GiB 的 Mac 会分配 8 GiB 虚拟机内存、4 GiB GPU 预算和 4 GiB 预留；
自定 9 GiB 虚拟机内存则只给图形留下 3 GiB。
设置 → 高级会显示两项额度；自定虚拟机内存给图形留下不足 2 GiB 或超出总量时会警告。
KosmicKrisp 和 MoltenVK 都通过 Venus 的 device-local 堆以及启用后的 `VK_EXT_memory_budget`
通告此预算，因此 zink 的 GL 内存查询与 DXVK/vkd3d 看到的是同一个较小堆，
而非 Mac 全部统一内存（STEAMAC-S）。`steamac.gpu_mib=` 也会更新 Steam 的显存报告层。
这用于引导游戏的纹理预算，并非硬性分配上限：游戏忽略预算或其他 Mac 应用占用预留内存时，
仍可能内存不足。此时请降低虚拟机内存或纹理设置。
在临时虚拟机中测试时，`--cmdline '… steamac.gpu_mib=3072'` 可覆盖宿主和客户机的报告值；
`host/virglrenderer/test/memory_budget.c` 查询堆和预算，并分配真实 GPU 缓冲直至通告的堆容量
（用 `VN_DEBUG=mem_budget` 暴露预算扩展；Venus 默认不启用）。切勿在开发者的磁盘上运行该分配测试。

**装更多游戏：** Mac 上的空闲空间不会自动变成 SteamOS 内的空闲空间。
home 容量在创建磁盘时固定。**设置 → 高级 → 扩展磁盘…** 可不重建磁盘、不删游戏地扩容
（只增不减，上限 4096 GiB）。对运行中的磁盘，
**扩展并重启** 正常关闭 SteamOS，虚拟机停止期间持有磁盘独占锁，扩大映像后再启动。SteamOS 用
`systemd-repart` 扩大末尾 home 分区，再用 `x-systemd.growfs` 扩大其 ext4 文件系统。其他启动器
也须停止；挂起的虚拟机仍持有磁盘。APFS / Mac OS 扩展格式按 SteamOS 实际写入占用新增空间；
exFAT 立即分配全部新增容量，故先检查其空闲空间。终端（SteamOS 停止时）：
`work/out/steamac-vm --grow-disk /path/to/steamos.img --home-gib 128`。

**回收 Mac 上的空间：** 卸载游戏（或大幅扩容）后，稀疏的 `steamos.img` 在磁盘上仍可能很大，
尽管 SteamOS 已不再需要那些块。**设置 → 高级 → 回收磁盘空间…**（需 SteamOS 运行中）让客户机对
`/home`（以及已挂载的 `/var`）执行 `fstrim`；virtio-blk DISCARD 在 Mac 映像上打洞。容量不变——
**仅当映像位于 APFS 上时**，已分配大小才可能下降。HFS+ 和 exFAT 无法以此方式回收空间；
启动器会在开始前检查卷。APFS 克隆和快照可能仍保留已释放的块，因此 Mac 的可用空间不一定
增加同样的数量。这不是缩小 GPT/home（仍只增不减）。

测试用：`STEAMAC_DEFAULTS_DOMAIN=<domain>` 替换设置域；`--selftest-settings
--selftest-out DIR` 无虚拟机打开窗口并为每选项卡写 PNG；`--control-fifo` 支持
`settings TAB`、`settings-dump PNG`、`set KEY VALUE`（与窗口等效）、`restart`。

### 单独配置游戏

**设置 → 游戏**为每个 Steam app id 保存配置，与鼠标自动捕获无关：
**图形**——默认（= Vulkan）/ Vulkan / DXMT；**Vulkan 驱动**——默认（全局驱动）/
KosmicKrisp / MoltenVK（仅提供可用的驱动）；**启动选项**——放在 `%command%` 前、以空格分隔的
`NAME=value`，不接受任意 shell 命令。整串不超过 256 个字符。变量名以 `VKD3D_`、`DXVK_`、
`PROTON_`、`WINE_`、`MESA_`、`RADV_`、`VK_`、`DXMT_`、`MTL_`、`STEAMAC_` 开头，
后接零个或多个 `[A-Z0-9_]` 字符；值匹配 `[A-Za-z0-9_.,:;+-]*`（允许空值）。
赋值按变量名排序，同名时最后一个生效。无效输入会保留并显示错误，不会保存或发送。字段为空表示该配置不添加任何覆盖（字段中不再显示看似强制值的 `VKD3D_CONFIG=dxr` 示例，STEAMAC-8X）。Metal Performance HUD 显示的是 Mac 的 drawable 尺寸，可能与游戏的渲染分辨率不同。

打开**设置 → 游戏**不会请求推荐。点击**获取推荐**或**重试**时，启动器会将游戏的 Steam App ID
以及本机的内存大小、GPU 核心数和性能核心数发送给统计服务，不受**共享游戏统计**设置影响。
服务根据这些**我的 Mac**限制从配置不高于本机的 Mac 中筛选配置，按
`(运行良好 + 0.5 × 可玩但有问题) / 全部评价` 排名，再比较更高的启动成功率和更低的过早退出率；
至少需要两个不同安装（详见[游戏统计](privacy-and-updates.md#游戏统计)）。找到的配置显示为
**推荐：… — 应用**，只有点击**应用**才会更改配置。

DXMT 需要启用**设置 → 高级 → 允许 DXMT（通过 Mac 的 Metal 运行 D3D11）**并以此权限启动虚拟机。
关闭时，DXMT 配置会标为未生效，并提供**允许 DXMT…**操作，保留原有安全警告；
仅启用 Vulkan 的启动中不会因此为游戏选择 DXMT 兼容工具。
Vulkan 驱动按**每次虚拟机启动**选择，而非按进程选择。游戏启动或获得焦点时，若配置的驱动与本次启动不同，
启动器会提议使用该驱动重启虚拟机，并在 Steam 就绪后重新启动游戏。
此覆盖仅限下一次启动，不更改全局驱动设置。

配置经双向 `fx.progress` 端口传输（一行一条消息）。宿主 → 客户机：
`profiles <UTF-8 JSON 的 base64>` 在本次启动首次收到代理心跳/ready 时及配置更改后替换整个集合；
`launch <appid>` 以会话用户身份运行 `steam steam://rungameid/<appid>`；
`restart-steam` 仅在用户同意后重启 `steam.service`。配置载荷为
`{"v":1,"games":{"570":{"gfx":"dxmt","env":"PROTON_LOG=1"}}}`；默认/空字段省略，
`driver` 仅保留在宿主。客户机原子写入 `~/.config/steamac/game-profiles.json`。
图形及游戏启动选项准备之前，ExecStartPre `steam-profiles-wait` 最多等待本次启动的同步 5 秒，
随后为最新可用集合建立快照（超时则使用持久化文件）。客户机 → 宿主：
`profiles-ok <JSON 的 sha256> applied|pending`；`pending` 表示正在运行的 Steam 使用了不同的配置集合，
启动器会提供**重启 Steam**或**稍后**。`game-gfx <appid> dxmt|vulkan` 紧随 `game-proton`，
根据 Proton 的 `.steamac-dxmt` 标记报告实际图形路径，而非本次启动是否允许 DXMT。
未知命令仍会被忽略，以兼容新旧宿主/客户机组合。

Steam 启动时，配置中的启动选项覆盖 `steam-title-defaults` 的内置条目；没有配置 `env` 时，
Dragon's Dogma 2 仍保留受 Venus 功能检查约束的默认值。所有权规则不变：用户之后在 Steam 中的修改优先；
替换或删除由 steamac 管理的启动选项不会累积旧赋值，删除后恢复原来的启动选项。
