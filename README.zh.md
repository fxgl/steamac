# steamac — Apple Silicon 上虚拟机中的 Valve 官方 ARM64 SteamOS（Steam Frame 映像）

[English](README.md) · [Русский](README.ru.md) · **简体中文**

在 macOS 15（Sequoia）上，Valve 为 Steam Frame 打造的真正的 SteamOS 运行在基于
Hypervisor.framework（libkrun）的轻量虚拟机中，经 Venus 实现 GPU 加速。

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

Metal 上的 Vulkan——默认使用 UTM 分支的 MoltenVK（几何着色器、robustness2）+
`VK_EXT_depth_clip_enable`（PR #2712）+ 我们的修复。KosmicKrisp（Mesa 在
Metal 4 上的 Vulkan 驱动）是 macOS 26+ 上的实验性替代（见“Vulkan 驱动”）。

## 要求

- Apple Silicon Mac，macOS 15+，约 150 GB 可用空间（磁盘映像为稀疏文件）。
- Xcode 26+（完整安装：其 `actool` 从 Icon Composer 文档构建应用图标）、Homebrew、rustup。
- KosmicKrisp（可选，替代 Vulkan 驱动）：仅在 macOS 26+ 上构建；`host/kosmickrisp/build.sh`
  会安装其 Homebrew 依赖（`llvm spirv-llvm-translator spirv-tools vulkan-loader glslang`）。
- OrbStack（或 arm64 且带 `--privileged` 的 Docker）：内核、Mesa 和磁盘映像在 Linux 容器中构建。
- Homebrew 包：`meson ninja pkg-config dtc xz lld sshpass go`（`go`：用于捆绑的 gvproxy/desync 的许可证清单）。
- libepoxy 1.5.10 由 `host/libepoxy/build.sh` 从锁定源码构建，先于 virglrenderer 和
  libkrun；三者均使用 `MACOSX_DEPLOYMENT_TARGET=15.0`，包括在 macOS 26/27 构建机上。
  打包会拒绝 Mach-O 部署目标高于 macOS 15.0 的文件（仅 KosmicKrisp 可要求 26.0）。

## 构建与运行

```sh
./build.sh          # 全部：MoltenVK、virglrenderer、libkrun、启动器、内核、Mesa、磁盘
./run.sh            # 一扇通往 SteamOS 的窗口
```

分别构建各部分：`./build.sh host`、`./build.sh guest`，或用下表中的脚本。
SteamOS 映像从 Valve 服务器下载（签名 RAUC 包）；校验其签名与
sha256。

发布版客户机产物附带 `.inputs.json` 构建收据，将选定的 Git
工作区输入与其输出字节绑定。相关脏修改使其失效；无关提交则不影响。
`host/launcher/bundle.sh` 在修改应用前拒绝缺失/过期收据；
`dist.sh` 在打包已有应用前也会校验其中的收据与资源。
报错会指明重跑哪一步。不碰现有 SteamOS
磁盘即可刷新客户机产物：`guest/kernel/build.sh`（其输入变化或收据缺失时才需要）、
`scripts/build-image.sh builder rootfs`、`guest/mesa/build.sh`，然后
`scripts/build-image.sh initramfs layer`；最后 `host/launcher/build.sh`。无戳记产物
正常构建一次即可；内核构建复用构建卷，无需 `clean`。
`ALLOW_NO_VENUS=1` 层仅用于测试，不可发布。

虚拟机选项：`./run.sh --display 1920x1080 --cpus 10 --mem 24576`（完整列表：
`work/out/steamac-vm --help`）。

帧节奏：`./run.sh --perf-stats`（或 `STEAMAC_PERF_STATS=1`）每 5 秒向终端打印客户机帧与上屏帧
间隔（p50/p95/p99/max，大于 25 与 50 ms 的区间数）。
新特效首次出现时的卡顿来自 Metal 着色器编译（每管线约 50–100 ms）；Metal
把结果缓存在磁盘上，之后不再卡，即使重启游戏或虚拟机（经 Venus 实测：新进程中每管线 102 ms → 0.95 ms）。

虚拟机中 Steam Shader Pre-Caching 与“允许 Vulkan 着色器后台处理”（设置 → 下载）
默认开启。Proton 的转码过场视频靠预缓存而来：Steam
按游戏下载（`steamapps/shadercache/<appid>/transcoded_video.foz`，如 Heroes of Might and
Magic: Olden Era 836 MB、Diplomacy is Not an Option 3.8 GB），经
`STEAM_COMPAT_TRANSCODED_MEDIA_PATH` 传给 Proton，由它播放 Proton 自身解不了的视频；
关闭预缓存后这些视频只显示占位。DXVK 自身缓存（DXVK 2.7）在游戏的
Wine prefix 中，两种情况都有效。代价：Steam 的 fossilize_replay 处理的每条管线都要由
Mac 上 Metal 编译（约 70–100 ms），Steam 在游戏着色器更新后会重新处理全部游戏，
启动器更新导致 MoltenVK 变化后也会全部重来（Venus 驱动身份是
MoltenVK `pipelineCacheUUID` 的哈希）。
后台处理在 Steam 空闲时完成大部；剩余部分在游戏启动时显示为“Processing Vulkan shaders”，可用
**Skip** 跳过。关闭：Steam → 设置 → 下载 → Enable Shader Pre-caching（和/或 Allow
background processing of Vulkan shaders）。

原生 Steam 保持后台处理关闭（`~/.local/share/Steam/config/config.vdf` 中没有
`EnableShaderBackgroundProcessing` 即视为 0）。Steam 启动前，
`/usr/lib/steamac/steam-shader-defaults`（`steam.service` 的 ExecStartPre）在
`ShaderCacheManager` 段中尚无值时写入
`"EnableShaderBackgroundProcessing" "1"`，每个 Steam 安装只写一次（标记 `config/steamac-shader-defaults`），因此在 Steam
设置中的选择会被保留。
启动器 1.4 把两项都关了（`"DisableShaderCache" "1"`、
`"EnableShaderBackgroundProcessing" "0"`）；更新后首次启动 Steam 时，脚本一次性把两项改回开启，但仅当两处仍恰好是这两个值时。

SteamOS 采用 Mac 的时区和 12/24 小时制（设置 > 通用中
**使用 Mac 的时区和时钟格式**，默认开启，下次启动生效）。
每次启动时启动器追加 `steamac.tz=<IANA zone of the Mac>`（`TimeZone.current`）和
`steamac.clock24=0|1`（本地化的 `j` 小时模板，遵循 macOS 的**24 小时制**开关）。
initramfs 把 `/etc/localtime` 指向该时区（`timedatectl`、Steam 经
`steamos-set-timezone` 的时区设置、Steam 时钟）。`/etc/steamac/mac-timezone` 记住上次应用的
时区；在 SteamOS 内选择的其他时区会被保留（直到再次与 Mac 时区相同）。
Steam 启动前，`/usr/lib/steamac/mac-clock-format` 更新该账号
`userdata/<account>/config/localconfig.vdf` 中
`UserLocalConfigStore/Software/Valve/Steam/FriendsUI/FriendsUIJSON` 的 `b24HourClock`。这是 Steam 的
设置 → 时间和日期 → 24 小时制开关，不是客户端全局设置：新磁盘登录前该文件
不存在，因此在登录后**首次启动 Steam 时**才生效。
桌面模式在 `~/.config/plasma-localerc` 中写入 `[Formats] LC_TIME`（24 小时制用 `en_GB.UTF-8`，
12 小时制用 `en_US.UTF-8`；同时决定时间/日期 locale）。上次应用的值与
用户独立覆盖保存在 `~/.config/steamac/mac-clock24.json`：在 Steam 或 Plasma 中修改格式
即停止跟随 Mac 的该项，另一项不受影响。
关闭启动器该设置后，时区与格式都不动。测试可显式传入
`--cmdline "console=hvc0 rootwait steamac.clock24=0"`（或 `1`），无需改 macOS 设置。

`ready` 之前启动与关机进度不会消失：窗口中的第一次点按或按键把全屏覆盖层收成底部中央的进度小条（阶段、
百分比、进度条、明细行如 `378 / 564 MB · 1.9 MB/s`；输入仍到达客户机）。点按小条或 显示 → 显示启动进度
可再展开；关闭覆盖层后（设置 > 通用），直接显示小条。新磁盘准备中或 Steam 客户端
下载 / 安装期间，点按与按键不收起覆盖层，之前被点按收起的覆盖层会自动展开（`overlay: expanded for
steam-download`）；经 显示 → 显示启动进度收起的则保持小条直到 `ready`。`ready` 之前窗口标题复述阶段：“FX Steam Launcher — 正在下载 Steam 更新 70%”、
“— 正在启动 Steam…”、“— 正在关机…”。日志记录 `overlay: collapsed to pill (click)` /
`expanded from pill`。`ready` 之后，若窗口 ≥ 3 秒无画面（scanout 关闭，或设置/调整大小后无帧到达），或所显示帧黑屏
≥ 5 秒（64 × 40 点稀疏采样，≥ 99.5% 亮度 < 8/255，每秒至多 4 次，约 3 µs），且焦点不在游戏中、客户机未睡 /
未暂停 / 未挂起，小条显示“等待 SteamOS 绘制…”并附原因、代理心跳与虚拟机 CPU 占用；
首个非黑帧到达即消失（`no-picture: shown after 5.0 s (black picture …)` /
`hidden after … (first non-black frame)`）。测试：
`work/out/steamac-vm --selftest-pill --selftest-out DIR`。

游戏获得焦点时（`focus game <appid>`），若客户机 2 秒无 GPU 命令（virtio-gpu
控制队列与 Venus 环——`krun_gpu_get_activity` 计数器），在最后一帧上浮现“仍在工作
 — 正在加载或编译着色器…”卡片并附虚拟机 CPU 占用；若客户机代理心跳也停止（> 5 秒），则显示“SteamOS 无响应…”
（此时与焦点无关）。空闲 Steam 界面几分钟无 GPU 命令属正常，不触发。首个 GPU 命令到达或焦点离开游戏即消失；每次出现都记日志（`stall: gpu idle 3.1 s (guest alive, …)`）。
`--perf-stats` 下每 5 秒加一行 `perf: gpu ctrl/s=… ring/s=… longest-idle=…`。在 设置 > 通用中关闭。代理跑在每个
gamescope 会话中（游戏模式与桌面模式）：会话结束时（切换到桌面、返回游戏模式），在新会话代理发来心跳前不期待心跳；虚拟机挂起或睡眠期间指示器关闭，恢复、客户机唤醒与 Mac 睡眠后，空闲与心跳计时重来。

| 窗口中的按键 | |
|---|---|
| Ctrl+Cmd+F | 全屏（macOS 开启游戏模式：Info.plist 声明为游戏——`LSApplicationCategoryType` `public.app-category.games`、`GCSupportsGameMode`、`LSSupportsGameMode`；`gamepolicyd` 记录 “Game mode status is now on”） |
| Ctrl+Cmd+G | 手动捕获 / 释放鼠标 |
| Ctrl+Cmd+P | Apple Metal 性能 HUD 开关（FPS、帧间隔、GPU 时间、内存）；另见 显示 → 显示 Metal 性能 HUD（Ctrl+Cmd+P） 与 设置 > 显示 |
| Ctrl+Option | 释放已捕获的鼠标 |
| 关闭窗口 | 关闭客户机（电源键） |

鼠标（`--mouse auto`，默认）：SteamOS 光标精确跟随 Mac 光标。gamescope
（游戏模式）不接受绝对坐标，启动器用无加速相对位移驱动它。当客户机中游戏获得焦点（代理发送 `focus game <appid>`），
首次点按捕获鼠标（视角用相对移动）；Ctrl+Option 释放。回到 Steam 时自动解除捕获。**鼠标**菜单：
- **在此游戏中捕获鼠标** — 当前游戏自动捕获（按 appid 保存）；
- **在游戏中自动捕获鼠标** — 所有游戏默认；
- **立即捕获或释放鼠标（Ctrl+Cmd+G）** — 同 Ctrl+Cmd+G。

这些与所有其他设置都在**设置**窗口（见下），域为
`es.fxgam.steamac`（`defaults read es.fxgam.steamac`）；首次启动时从旧域 `dev.steamac.vm`
一次性拷贝。Metal 按应用标识存着色器缓存，改标识后游戏首次启动会重新编译着色器（一次“冷”启动）。
`--auto-capture on|off` 覆盖单次启动的默认值。
`--mouse tablet` — 绝对平板（gamescope 不理会，只适用于客户机其他合成器），
`--mouse capture` — 点按即捕获。

客户机访问：`ssh -p 2222 steamos@127.0.0.1`，密码 `steamos`（经
`STEAMOS_PASSWORD=... scripts/build-image.sh disk` 修改）。hvc0 控制台在运行
`run.sh` 的终端中。

SSH 一键开关：**设置 → 高级 → 启用 SSH**（或 `--ssh-port N` /
`--no-ssh`）。每次启动时启动器传递 `steamac.ssh=0|1`：为 0 时 Mac 上根本不开端口
（无转发的 gvproxy），initramfs 在 SteamOS 中屏蔽 sshd。开发版启动器（`work/out/steamac-vm`、`./run.sh`，端口 2222）默认开启，
`FX Steam Launcher.app` 默认关闭（Info.plist 中 `SteamacReleaseDefaults` 键，由 `bundle.sh` 设置）。开启后，
启动器为 `steamos` 用户生成密码（20 字符，SecRandomCopyBytes），
按磁盘 GPT GUID 分别存于钥匙串，下次启动只把其 SHA-512 crypt 哈希传给客户机（“配置载荷”盘，`steamac.config=1`；客户机回复
`config applied`）。设置中显示用户、密码（显示/拷贝）、现成命令
`ssh -p … steamos@127.0.0.1`、状态“密码已在 SteamOS 中生效 / 密码将在下次启动时生效”与**重新生成密码**；
开发版启动器仅经按钮生成密码（Docker 构建的磁盘保留 `steamos`）。应用内创建的磁盘只经此途径获得密码——没有默认密码。终端中：
`steamac-vm --ssh-password <disk>` 打印用户、密码与状态。

### 局域网与 Steam Remote Play

普通联网走 gvproxy 用户态 NAT（SteamOS 中 `192.168.127.2`）；局域网广播过不了该 NAT。**设置 → 高级 → 局域网 Remote Play**（下次启动生效）或
`--lan-remote-play` 启用启动器侧发现中继与同端口转发：
Mac 到客户机的 UDP **27031–27036**、TCP **27036–27037**。默认**关闭**：
开启会把 Steam 的 Remote Play 服务暴露给其他机器，与 SSH 无关。
`--no-lan-remote-play` 单次启动关闭；网络关闭则一并关闭。

允许 macOS 的**本地网络**权限，并在 Mac/SteamOS 防火墙放行入站。
Steam Link 与 Mac 须在**同一 IPv4 子网**（Wi-Fi 客户端隔离、访客网络、VLAN、路由发现与纯 IPv6 局域网不受支持）。在客户机 Steam 中启用 Remote Play；
手动配对请用 Mac 的局域网地址，而非 `192.168.127.2`。
若 Mac 本机 Steam 客户端占用这些端口请先退出：启动器从不共享或抢占
UDP 27036，冲突记为 `remote-play: disabled for this boot` 并回滚转发。
Mac 版 Steam 自身的 UDP 27036 广播不会回灌客户机。

中继保留 Steam 客户端身份与未知 protobuf 字段，把状态中的地址提示替换为 Mac 局域网 IPv4 地址，
端口因同端口转发而保持。客户机状态公告每五秒由真实发现查询刷新
（gvproxy 不导出客户机子网自主广播）；Steam 无应答时不虚构状态。未登录的 Steam 可能不宣告主机。
`--selftest-remote-play` 不启动虚拟机即可检查包解析与地址改写。
真实局域网探测（在 Mac 或第二台机器上）：
`python3 scripts/test/remote-play-discovery.py --bind <LAN-IP> --broadcast <subnet-broadcast> --expect-host <Mac-LAN-IP>`。
它用临时端口，打印 Steam 实际回复与改写后地址，无应答即失败；不保证配对或串流成功。
协议参考：[Valve Remote Play 网络设置](https://help.steampowered.com/en/faqs/view/3E3D-BE6B-787D-A5D2)、
[Steam 远端 protobuf](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_remoteclient_discovery.proto)、
[发现包封帧](https://github.com/OpenSourceLAN/steam-discover/blob/master/listener.js)。

## 设置窗口

**FX Steam Launcher → 设置…**（Cmd+, ——客户机持有键盘时也可用）。每项标注“立即生效”或“下次启动时生效”。
若改了后一组中的任何项，底部出现 **重启虚拟机以应用**：
客户机经电源键正常关机，监管器用新值重新启动虚拟机（**重启虚拟机**菜单项同理）。命令行标志优先于保存值，但仅对当次启动有效：字段旁显示“已被命令行覆盖
（--cpus 6）”。

| 选项卡 | 立即生效 | 下次启动时生效 |
|---|---|---|
| 通用 | 开关机覆盖层；GPU 空闲“仍在工作 — 正在加载或编译着色器…”指示；“当 FX Steam Launcher 在后台时”：**静音**（默认开：`krun_snd_set_volume(…, mute)` 约 150 ms 渐隐，切回窗口恢复音量）与**暂停游戏**（默认关：客户机代理只冻结焦点游戏——`systemctl --user freeze app-steam-app<appid>-*.scope`，cgroup v2；Steam、下载与更新继续；在线游戏可能断线）。代理确认冻结期间（`game-frozen`/`game-thawed`）窗口变暗并显示“游戏已暂停 · 点按以继续”卡片与标题“— 已暂停”；点按窗口恢复游戏且不传给客户机；崩溃报告（`--no-crash-reports`，见下）；**启动时检查更新**（默认开，见“更新检查”）；帧统计日志（`--perf-stats`） | 启动时全屏；**使用 Mac 的时区和时钟格式**（默认开，见上） |
| 显示 | 客户机跟随窗口大小；窗口右上角 Apple Metal 性能 HUD（Ctrl+Cmd+P，显示菜单）；**MetalFX 超分辨率**（默认关）：窗口像素多于客户机时（Retina 屏 2 倍、缩放或全屏窗口），Apple MetalFX 空间放大把客户机画面放大到窗口像素尺寸，而非线性 / 最近邻缩放；跑在启动器中的客户机帧上，对所有游戏与 Steam UI 有效 | 物理尺寸来源（屏幕自动 / DPI / 毫米——`--dpi`、`--display-mm`），刷新率（`--refresh`），窗口大小（`--display`）：1280 × 800（Steam Deck）到 3840 × 2160 的标准分辨率（超出显示器的标注“超出当前屏幕尺寸”；窗口照旧缩小），“适应屏幕”（按显示器取最大，每次启动重算）或“自定…”（宽 × 高输入）；**Retina 分辨率**（可选，默认关）：客户机显示器获得屏幕像素密度（窗口点数 × 启动时屏幕 backing scale，每边不超过 4094 px 者降档），EDID 物理尺寸不变，SteamOS 把 UI 放大到同样尺寸、文字锐利——但游戏要画 4 倍像素，每帧拷贝大 4 倍；更推荐：Retina 分辨率关 + MetalFX 超分辨率（Retina 屏 2 倍放大） |
| 鼠标 | 游戏中自动捕获；游戏列表（名取自 `appmanifest_<appid>.acf`，使用默认/自动/关闭、忘记此游戏） | — |
| 控制器 | 哪个物理控制器（GameController）驱动虚拟手柄（首个已连接或自选），SteamOS 是否获得手柄及呈现为何种（`--no-gamepad`、`--pad`，见“控制器”），DualSense 是否按本身直通，A/B 与 X/Y 互换，摇杆死区，实时输入测试 | — |
| 声音 | 输出设备（系统默认跟随 macOS，或指定 CoreAudio 设备），音量/静音，低（10 毫秒）/普通（20 毫秒）/稳定（60 毫秒）缓冲——经 `krun_snd_set_*`（`dlsym` 查找；旧 libkrun 下字段置灰并说明） | 声音（`--no-sound`） |
| 高级 | — | vCPU（`--cpus`）、内存（`--mem`）、SSH 开关 + 端口（`--ssh-port`、`--no-ssh`）与生成密码、网络（`--no-net`）、磁盘映像（`--disk`）、新建磁盘…、Steam 客户端（`--steam-client`，见“Steam 客户端”）、Vulkan 驱动（`--vulkan-driver`，见“Vulkan 驱动”） |

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

测试用：`STEAMAC_DEFAULTS_DOMAIN=<domain>` 替换设置域；`--selftest-settings
--selftest-out DIR` 无虚拟机打开窗口并为每选项卡写 PNG；`--control-fifo` 支持
`settings TAB`、`settings-dump PNG`、`set KEY VALUE`（与窗口等效）、`restart`。

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

## 桌面模式

Steam → 电源 → **切换到桌面**启动 KDE Plasma；桌面的**返回游戏模式**图标回去。在 Steam Frame 映像上该模式是 VR 桌面（`plasma-session.target` 想要
SteamVR，虚拟机中已屏蔽），层将其替换：`plasma-session.target` 与
`steamac-nested-desktop.service` 在同一 gamescope 中把 Plasma 跑成一个 KWin 窗口
（`/usr/lib/steamac/nested-desktop`，如 Valve 的 `steamos-nested-desktop`），按显示尺寸，gamescope
1:1 显示。`gamescope-onready` 等该服务：Plasma 退出即会话结束，SDDM 重新登录。Plasma 有独立运行时目录与 D-Bus 会话总线；层的
`steamosctl` 垫片（`/usr/lib/steamac/desktop-bin`，其 PATH 首位）把返回游戏模式等 SteamOS 命令发往外部会话总线，由 steamos-manager 执行。桌面 Steam 自启动（`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`）保留启动器所选客户端，而非原生 `-deckard`（Frame 客户端），否则每次切换都下载另一客户端。进度代理上报 `focus desktop <w>x<h>`（Plasma 窗口）：启动器保持相对指针，按 gamescope 缩放映射到该窗口；直启桌面模式（`steamos-session-select plasma-persistent`）在桌面就绪时上报 `ready`。

Flatpak 应用（Discover）跑在 bubblewrap 中，在用户命名空间挂载自有 procfs。内核仅当挂载命名空间中有完全可见的 procfs 才允许，而 initramfs 把合成 `/proc/cmdline` 覆盖了真实文件；因此它还在
`/run/steamac/proc` 挂载一份 untouched procfs（`nosuid,nodev,noexec`）。没有它每个 Flatpak 应用都以 `bwrap: Can't mount
proc on /newroot/proc: Operation not permitted` 退出。

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

## 控制器

macOS GameController 框架支持的任何控制器（Xbox、DualSense、DualShock 4、MFi……）
都在 SteamOS 中驱动一个手柄；设置 → 控制器选择用哪一个。该手柄不是 virtio-input
设备：启动器经 virtio-console 端口 `fx.pad` 发往客户机 root 服务
`fx-pad.service`（`fx-progress-agent pad`，端口出现时由 udev 启动），由它经 uinput 创建。
因此虚拟机运行时它跟随 Mac：控制器连接即出现（Steam 显示“Controller Connected”），最后一个断开即消失，种类随之变化。
设置 → 控制器 → **在 SteamOS 中显示为**（单次启动用 `--pad auto|xbox360|dualsense|dualshock4`）：

- **自动**（默认）：与驱动它的控制器同类——DualSense（或 Edge）→
  DualSense，DualShock 4 → DualShock 4，其他 → Xbox 360 手柄；
- **Xbox 360 控制器**：内核 `xpad` 驱动呈现的样子（`045e:028e`）；
- **DualSense** / **DualShock 4**：USB 手柄的 `hid-playstation` / `hid-sony` 呈现的样子
  （`054c:0ce6` / `054c:09cc`，版本 `0x8111`，按键按位置，模拟扳机旁另有数字 L2/R2）。Steam 的 SDL 将其映射为 PS5 / PS4 手柄并显示 PlayStation 图标。

**振动。** 手柄带 `FF_RUMBLE`，如真实驱动，SDL 与 Steam 可驱动振动——经 Steam Input 的游戏经 Steam 虚拟 Xbox 手柄触达。uinput 把回放交给用户态驱动：`fx-pad` 实现内核 ff-memless 规则（延迟、时长、重复、重载、效果叠加）并向启动器发送合成等级 `rumble <strong> <weak>`，启动器用 GameController 触觉播放：强电机左手、弱电机右手（无分 TW 电机的控制器 whole one level）；虚拟机挂起期间无振动。端口协议：`guest/progress-agent/src/pad.rs`。触摸板、陀螺仪、光条与自适应扳机是真实控制器的 HID 功能，该 evdev 设备没有。

**DualSense 直通。** 当 DualSense（或 Edge）驱动手柄且呈现为 DualSense 时，设置 → 控制器 → **直通 DualSense**（默认开，立即生效）把控制器本身而非 uinput 手柄交给 SteamOS。启动器以裸 HID 设备打开它
（IOHIDManager，不独占：GameController 照常选中并可唤醒睡眠客户机），
`fx-pad` 用 `/dev/uhid` 重建它：相同报告描述符、vendor/product、USB 或蓝牙总线。客户机
`hid-playstation` 驱动如对插入的控制器一样绑定（手柄、
触摸板、体感、光条与玩家 LED、静音 LED），Steam 用自家 HIDAPI
DualSense 驱动操作 `/dev/hidraw*`，Steam Input 获得触摸板、陀螺仪与静音键，
自行驱动振动、光条与自适应扳机。输入报告原样进客户机
（`hid-input`）；输出报告、GET_REPORT 与 SET_REPORT 回控制器（`hid-output`、
`hid-get` / `hid-get-reply`、`hid-set` / `hid-set-reply`，hex，报告 ID 在首）。客户机跟不上时丢弃旧输入报告而非排队：每份报告都携带完整状态。A/B 互换与摇杆死区对直通控制器无效。GameController 不报告控制器对应哪个 HID 设备：多 DualSense 时直通第一个找到的。无 `caps hid` 的旧客户机层仍获得 uinput 手柄。

`--control-fifo` 测试命令：`pad on`（无控制器的手柄，如 `--input-selftest` 所用）、
`pad off`、`pad test`（A + 左摇杆）、`pad state`（客户机手柄、上次振动等级、客户机是否接管 HID 设备、已连接 DualSense 与直通输入报告数）。

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
`work/out/steamos.img`（包旁边或构建处）。无磁盘时，首次启动窗口提供**新建磁盘…**（见下节）或**使用已有磁盘…**
（映像就地使用从不复制；`scripts/build-image.sh` 也可构建）。此模式客户机控制台与启动器日志写入
`~/Library/Logs/es.fxgam.steamac/steamac-vm.log`；SIGUSR1 帧转储亦然。`./run.sh`
与 `work/out/steamac-vm` 照常用（除非被标志覆盖，窗口设置对它们同样有效）。

映像在外接盘上时，首次从访达启动 macOS 会问“FX Steam Launcher
想访问可移动宗卷上的文件”——允许（回应前虚拟机等待磁盘打开）。ad-hoc 签名，重建包后 macOS 可能再问。

一个磁盘映像一次只能被一台虚拟机使用：虚拟机进程退出前持有可写磁盘独占锁
（`flock`），第二个启动器（应用的另一份拷贝，如 `/Applications` 旁的源码构建，或 `steamac-vm`）以“SteamOS 已在运行”拒绝启动，而非两次挂载同一文件系统（那会损坏 `/home` 与 `/var`）。启动器被杀而客户机仍在关机时，锁会存活。加锁之前的启动器不检查。

若启动时 `/home` 仍有错误（虚拟机被杀时正在写，或一块盘被两个无锁旧启动器用过），SteamOS 会修复而非卡在“正在启动 SteamOS 服务…”：启动器在内核命令行加 `fsck.repair=yes`，systemd-fsck 用回答 yes 的 e2fsck 而非仅安全 preen 修复。e2fsck 放不回去的文件进 `/home/lost+found`。

## 语言

启动器界面提供英语、俄语和简体中文，跟随 macOS 语言（系统设置 → 通用 → 语言与地区，也可在“应用程序”中为单个应用设置）。日志、命令行输出、崩溃报告与问题报告保持英文。客户机代理发送的固定 Steam 阶段文本（“Checking for Steam updates”等）会显示为译文（`BootProgress.localizedGuestText`）；其他客户机文本（systemd 行、SteamOS 本身）启动器不翻译。

字符串保存在 String Catalog 中：`host/launcher/Localizable.xcstrings`（键为英文原文）与
`host/launcher/InfoPlist.xcstrings`（权限提示）。代码中 SwiftUI 字面量（`Text("…")`、`Button("…")`）自动本地化；其他界面字符串一律写作 `String(localized: "… \(value) …")`——每个键一句完整的话、参数用插值、不拼接片段——而日志与 CLI 文本保持普通英文字符串。`host/launcher/build.sh` 以 `-emit-localized-strings` 编译，把提取的键同步进目录（新键加入、删除的标记为 stale——目录随代码一起提交），列出未翻译的键与格式参数不一致（`host/launcher/l10n.py check`），并把目录编译为 `work/out/steamac-vm` 旁与应用 `Contents/Resources` 中的 `<lang>.lproj`。语言不完整时 `dist.sh` 拒绝发布。不用 Xcode 翻译：`host/launcher/l10n.py export zh-Hans todo.json` 列出缺失项，`host/launcher/l10n.py import zh-Hans done.json` 导入 `{"键": "文本"}`；Xcode 也可直接打开这些目录。不改系统语言而检查某种语言：`work/out/steamac-vm -AppleLanguages '(zh-Hans)' …`。

## 无需 Docker 创建 SteamOS 磁盘

应用用户不需要 Docker：启动器自己创建磁盘——经首次启动窗口的**新建磁盘…**或**设置 → 高级 → 新建磁盘…**（stable/rc
分支、home 大小、位置、`steamos` 用户密码；进度、停止与创建）。只提供 stable 与
rc：beta/preview/main 可能用 Valve 开发签名密钥，启动器不信任。已保存的不支持分支回落 stable 并记日志。不带窗口亦可：

```sh
work/out/steamac-vm --create-disk ~/steamos.img [--branch stable] [--home-gib 64] [--password PW] [--keep-cache] [--accept-eula]
```

用户接受 Valve 条款前不下载任何东西：“SteamOS 与 Steam 客户端备份映像最终用户许可协议”（与 Steam Frame 映像页相同文本，
`https://store.steampowered.com/steamos/download/?ver=steamframe`：仅个人使用、禁止再分发）与 Steam 订户协议。窗口中为带两个文本链接的复选框——不勾选无法创建；命令行用 `--accept-eula`，
无此标志 `--create-disk` 打印链接并以代码 2 退出。接受记录（日期与协议 URL）存于设置域，代码中协议 URL（`SteamOSLicense.eulaURL`）变化前一直有效。

外接 APFS、Mac OS 扩展与 exFAT 卷可存放磁盘。FAT32/MS-DOS 因 4 GiB 单文件限制在下载前拒绝
（临时 rootfs 就 10 GiB）。只读卷和没有写入权限的文件夹同样会被拒绝。与 APFS 不同，exFAT 无稀疏文件：即使游戏还没装，也需要所选磁盘全尺寸加临时 rootfs 与下载缓存的空间；启动器先检查空间再重建 rootfs。
这些预期拒绝（包括目标文件已存在、下载缓存正被使用）只记入日志，不作为错误发送到 Sentry。
非预期创建失败仍会上报：Foundation 错误按域和错误码分组，原始技术诊断放在事件详情中，
而不是把指针或任务 ID 放进标题。

如果下载无法安全连接到 Valve，窗口会提示 VPN、代理或网络过滤器可能造成干扰：
请尝试关闭它们或更换网络。连接 GitHub 的更新检查也会给出同样建议。
技术细节保留在启动器日志中。HTTPS 使用 macOS 标准证书验证和 TLS 设置；
下文固定的 Valve CA 用于验证下载的包，而非 HTTPS 连接。

`rc` 仍可选择，但 Valve 有时用开发密钥 `steamos-dev-images` 而非生产 CA 签署最新构建。
启动器不接受这种构建：窗口会说明无法验证该开发签名，请选择 `stable` 或稍后再试。
这种预期拒绝只记日志；其他签名验证失败仍会上报 Sentry。

1. `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<branch>.json` → 最新候选（`update_path`、`chunks_store_path`）。
2. 下载 `.raucb`（约 2 MB）；Security.framework 仅对照 Valve 固定 CA `CN=steamdeck-images`（`scripts/keys/steamdeck-images.pem`，SHA-256 指纹嵌入代码）校验其 CMS 签名，不用系统信任库。自研 squashfs 读取器（用锁定 zstd 发行版的 zstd，`fetch-zstd.sh`）解出 `manifest.raucm` 与 `rootfs.img.caibx`；检查
   `compatible=steamos-aarch64`、版本与槽大小。
3. 官方 desync（`fetch-desync.sh`，锁定版本与 sha256）从 Valve 块存储（约 4.4 GB 数据）组装 10 GB `rootfs.img`；家目录卷上的磁盘用
   `~/Library/Caches/es.fxgam.steamac` 中的 `desync/` 做块缓存，否则用磁盘旁 `<disk>.cache`
   （外接盘则内部不占缓存空间；成功后删除该目录）。`<disk>.rootfs-tmp` 也保留，故停止/创建（或 Ctrl+C 后重跑命令）可断点续传。一个缓存一次只允许一次创建：第二次（另一窗口或 `--create-disk`）以“另一个 SteamOS 磁盘正在使用下载缓存 … 创建：请等待创建完成或取消该操作”停止（缓存目录中 `creation.lock` 的 `flock`），而非共享块缓存与临时文件。
4. 稀疏磁盘文件：保护 MBR + GPT（主备，CRC32），名称、顺序、类型、大小与对齐与 `scripts/steps/40-disk.sh` 完全一致，PARTUUID 随机。一遍写入中，对 `rootfs.img` 哈希（sha256 须与签名 manifest 一致），16
   KiB 非零块写入 rootfs-A 与 rootfs-B；其余分区写零。全部检查通过后磁盘才以最终名称出现。已存在文件从不覆盖；exFAT
   无原子独占改名，启动器持创建锁检查目标后再改名。创建期间勿用非启动器程序向同一目标创建或移动其他文件：该检查与改名对它非原子。
5. 旁边放置 `<disk without .img>.provision.img`——cpio newc，内含
   `provision.env`（构建、PARTUUID、SHA-512 crypt 密码哈希、machine-id）与 `rootfs.caibx`
   （格式见预配契约“Payload v1”）。该文件存在期间，启动器只读挂载它（vdc）并加 `steamac.provision=1`：initramfs 格式化
   esp/efi-X/var-X/home，使 rootfs-B fsid 唯一，写入 partsets/bootconf/bootenv/var，
   并上报 `provision done`——之后启动器删除载荷；后续启动不再使用。

空间：创建期间磁盘卷约 14 GB（成功后约 9 GB），缓存约 6 GB（除非 `--keep-cache`，成功后删除）。检查：`work/out/steamac-vm --selftest-provision`——
GPT 对 Docker 构建磁盘（`work/out/steamos.img` 只读打开；
`--reference-disk IMG`），CMS/squashfs 对 `work/cache/rootfs` 缓存，cpio、SHA-512 crypt。
自测还检查网络提示、稳定的错误指纹，以及仅记日志的位置拒绝。
要在不发送任何事件的情况下触发真实 TLS 失败，运行 `--selftest-provision` 时将
`STEAMAC_PROVISION_TEST_TLS_URL=https://localhost:PORT/` 指向使用不受信任证书的本地服务器；
它会打印提示、标题与指纹。

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
| **Steam Deck 客户端**（`deck`，默认） | 公开 ARM64 Steam Deck 客户端，`steamdeck_stable` 分支（与公开 `steam_client_linuxarm64` 同构建；ARM 版未官宣） | 屏幕二维码正常登录（Steam 手机 App → Steam 令牌 → 扫码）外加密码表单；公开客户端分支而非内部测试版 |
| **Steam Deck 客户端（测试版）**（`deckbeta`） | `steamdeck_publicbeta` 分支 | 同 `deck`，测试版 |
| **Steam Frame 客户端**（`frame`） | Valve 的 Steam Frame 测试版客户端（`linux_arm64_beta_<hash>`，参数 `-deckard -vrgamepadui`）——如映像自带 | 映像自带客户端；未发售设备的内部测试版；登录走下述登录模式 |

切换选项下次启动下载另一客户端（至多约 1 GB，
启动覆盖层可见进度）；切回 Frame 时 Steam bootstrapper 按 `-deckard` 标志自动切换。SteamOS 内手写
`/etc/steamac/steam-client-branch`（任意客户端分支）选 `frame` 时仍有效（或启动器不传参数时——旧版本、自定 `--cmdline`）；启动器的 `deck` / `deckbeta` 选择优先于该文件。

## Vulkan 驱动

Venus 背后的宿主 Vulkan 驱动在**设置 → 高级 → Vulkan 驱动**选择（下次启动生效），单次启动用 `--vulkan-driver moltenvk|kosmickrisp`。默认 Mac 与构建都有 KosmicKrisp 处用它
（macOS 26+、macOS 26+ 上构建），否则 MoltenVK；设置中选定则保持。virglrenderer
运行时打开驱动（无 Vulkan loader）：启动器在虚拟机启动前设置 `VKR_VULKAN_DRIVER` 为
`@rpath/libMoltenVK.dylib` 或 `@rpath/libvulkan_kosmickrisp.dylib`。启动覆盖层显示驱动（“Venus → KosmicKrisp”）；崩溃报告带 `vulkan_driver` 与驱动补丁版本。

Metal 初始化前，启动器检查运行时编译器的模块缓存是否可写
（`DARWIN_USER_CACHE_DIR/<bundle id>/com.apple.metalfe`，包括现有哈希目录和 `.pcm` 文件）。
如果权限、ACL 或不可变文件标志阻止写入，启动器会记录失败路径，
并把 Metal 缓存重定向到 `~/Library/Caches/es.fxgam.steamac/metal-compiler`。
它不会删除旧缓存或修改其权限。此功能使用 Metal 可选的缓存路径 SPI；
若该接口不可用或新缓存同样不可写，会记入日志，着色器编译错误仍可上报。
`work/out/steamac-vm --selftest-metal-cache` 在私有不可变缓存中复现
`monolithic_metal.pcm: Operation not permitted`，随后用新缓存验证真实 Metal 源码编译
（不启动虚拟机、不发送 Sentry 事件）。

| 选项 | 是什么 | 利弊 |
|---|---|---|
| **KosmicKrisp** — Mesa on Metal 4 · macOS 26+（`kosmickrisp`，可用时默认） | `host/kosmickrisp/`：Mesa 主线 + 未合并 MR（几何着色器 !44786、transform feedback !44928、宿主指针内存中的平铺图像 !44929、device-local 内存类型 !44221、线性渲染目标 !44782/!44222）+ steamac 补丁（显式 LINEAR 行距、LINEAR 输入附件、DXVK 所需的 `fillModeNonSolid`、8 倍采样请求按 4 倍处理、vkd3d-proton 所需的 texel 缓冲单 texel 对齐与跨多个 Metal 计数器堆的时间戳池；遮挡查询可超出单个 32768 条目的可见性缓冲，时间戳池使用进程内所有客户机设备共享的计数器堆（Metal 每进程只允许 32 个），因此 Dota 2 / Counter-Strike 2 的查询池不再创建失败；基于 Metal 4 placement sparse resources 的稀疏绑定与驻留，在 Apple10 之前的 GPU 上用着色器模拟采样器 min/max reduction，为 vkd3d-proton 提供 Tiled Resources Tier 2，从而支持 D3D12 功能级别 12_0） | 更快：M1 Max 上 Stellar Blade 试玩版约 29 FPS，MoltenVK 约 18（分屏视频：`docs/media/stellar-blade-moltenvk-vs-kosmickrisp.mp4`）；Steam UI、DXVK 游戏和 Stellar Blade 试玩版（D3D12，vkd3d-proton）可运行，后者在 M1 Max 上首次运行需约 28 分钟编译着色器。仅 macOS 26+；构建机也必须运行 macOS 26+，否则使用 MoltenVK。已知缺口（宿主复现）：带条带几何着色器的 transform feedback 及其溢出计数器（草案 MR）；同一渲染通道内，对未映射图块的深度写入保留在图块内存中，后续绘制仍会用这些值做深度测试（Tiled Resources Tier 2 允许该缓存；vkd3d-proton 的 `test_sparse_depth_stencil_rendering` 则期望丢弃）；不支持稀疏 3D 纹理（Metal 的 3D 图块不符合 Vulkan 标准 3D 块布局），因此没有 Tiled Resources Tier 3 |
| **MoltenVK** — Metal 3 · macOS 15+（`moltenvk`） | `host/moltenvk/`：UTM 分支 + steamac 补丁 | 所有受支持 Mac；macOS 15 默认，无 KosmicKrisp 的构建也默认（macOS 15 源码构建；1.7 起发布 DMG 含 KosmicKrisp） |

切换改变 Venus 驱动身份（管线缓存 UUID），Steam 与游戏重建着色器缓存。宿主驱动建不出的管线在 virglrenderer 中是占位：其绘制与派发被丢弃，驱动永远见不到 `VK_NULL_HANDLE`。

每个宿主可见客户机分配都是一块 POSIX shm，其文件描述符在虚拟机进程中保持打开（每映射分配约四个），访达启动的进程软限制 256 个描述符：几十个此类分配后游戏丢失 GPU 上下文（STEAMAC-G、Left 4 Dead
2）。虚拟机进程启动时把软限制提到 `kern.maxfilesperproc`（记为“file
descriptors: soft limit 256 → N”）；virglrenderer 记录失败 shm 或描述符操作的 errno（“… failed: Too many open files (RLIMIT_NOFILE 256)”）。

无虚拟机检查：`host/kosmickrisp/build.sh` 对暂存驱动运行 `host/moltenvk/probe` 与复现
（`REPRO_DRIVER=kosmickrisp host/moltenvk/repro/run.sh <dylib>`，经 Khronos loader，仅测试）；`host/virglrenderer/build.sh` 对各已装驱动运行 `venus_check`。

## 登录

Steam Frame 客户端登录屏为头显设计：“轻触确认”经蓝牙 LE 配对手机，“扫描二维码”打开 VR 窗口——虚拟机中两者皆不可用（只剩密码）。因此 Frame 客户端下，当 `config/loginusers.vdf` 无记住的账号（新磁盘、退出登录、未勾“记住我”登录），`steam-client`
去掉 `-deckard`/`-vrgamepadui` 启动 Steam：bootstrapper 自动切换到公开
ARM64 Steam Deck 客户端（`steamdeck_stable`），登录显示屏幕二维码（Steam 手机 App → Steam 令牌 → 扫码）与密码表单。勾选“记住我”登录后，Steam 重启一次回到 Steam Frame 客户端（每次客户端切换下载至多约 1 GB；
启动覆盖层可见进度）。连不上 `client-update.steamstatic.com` 则不启用登录模式。

登录屏 `connection_log.txt` 中 `RecvMsgClientLogOnResponse() : 'Try another CM'` 属正常：CM 服务器约 60 秒踢掉无账号登录的连接，客户端重连。

## 分发（DMG）

`host/launcher/dist.sh` 把构建好的 `work/out/FX Steam Launcher.app` 做成可下载的
`work/out/dist/FX-Steam-Launcher-<version>.dmg`（应用 + `/Applications` 链接）。去掉 `SteamacBuildOut` 键（本构建树路径）的包拷贝用 Developer ID
重签，hardened runtime，安全时间戳：先签全部内嵌 Mach-O（`Frameworks/*.dylib`、`Resources` 中辅助程序），
再用 `steamac-vm.entitlements` 签包（hypervisor、
disable-library-validation 与音频输入——缺后者 hardened runtime 会静默挡住麦克风）。应用公证并装订，DMG 签名、公证、装订——
Gatekeeper 离线也放行（首次打开仍有常规“来自互联网”提示）。

```sh
host/launcher/build.sh      # 全新包
host/launcher/dist.sh       # 签名、公证、DMG
```

须在钥匙串存一次 notarytool profile：
`xcrun notarytool store-credentials steamac-notary --apple-id <Apple ID> --team-id V25VKGTW55
--password <app-specific password>`。变量：`STEAMAC_SIGN_IDENTITY`（默认钥匙串中唯一的
“Developer ID Application”），`NOTARY_PROFILE`（默认 `steamac-notary`）；
`--no-notarize` ——只签名，用于本地检查（下载副本会被 Gatekeeper 拒绝）。

许可证：`bundle.sh` 把捆绑组件第三方许可文本与
`THIRD-PARTY-NOTICES.txt` 索引（组件、版本、SPDX、包内位置、源码；由 `host/launcher/licenses.sh` 在 `work/out/licenses` 生成，含 libkrun crates 与 gvproxy/desync 的 Go 模块）放入 `Contents/Resources/licenses`，项目 `LICENSE` 与 `NOTICE` 在
`licenses/steamac/`。`dist.sh` 调用 `scripts/gpl-sources.sh` 并把
`work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar` 放在 DMG 旁——GPL 组件完整源码
（带补丁与配置的内核、Debian 快照 busybox、
dosfstools、e2fsprogs、btrfs-progs、构建脚本、`README.txt`）；随 GitHub release 附 DMG 发布。
旧版本：`scripts/gpl-sources.sh v1.2`。

## 崩溃报告（Sentry）

启动器向开发者自己的 Sentry 服务器（`sentry.fxgam.es`，经 SwiftPM 的
sentry-cocoa 9.30.0 SDK）发送崩溃报告与少量错误。
默认开启；设置 → 通用中**发送崩溃报告和诊断信息**复选框、首次启动窗口或创建 SteamOS 磁盘窗口可关闭（“发送内容”链接展示下表）。关闭后
SDK 根本不启动、不联网（已落盘报告保留在原处、不发送）。单次启动：`--no-crash-reports` 或 `STEAMAC_SENTRY=0`。

发送内容：

- 监管器与虚拟机进程崩溃（信号/abort、未处理异常）：原因、线程堆栈、已加载库。含 Metal/MoltenVK 断言、libkrun/virglrenderer
  abort、经 libkrun C API 传出的 Rust panic。虚拟机进程崩溃报告在下次启动虚拟机时发送；
- 少量错误（每进程每指纹至多一次，有全局上限；同一指纹至少一天、着色器编译错误 30 天内不重发）：客户机 GPU 上下文 fatal/device lost（vkr “fatal decoder state”、“device lost”）、MoltenVK
  管线编译错误（`[mvk-error] … compile failed`；MoltenVK 若打印 MSL 源码
  （`[mvk-msl] …`：前 40 行与出错前后行）放 extra `msl_source` 而非面包屑；vkr “pipeline … creation failed on host” 只做面包屑）、libkrun 中 Rust panic（`thread … panicked at`）、首次磁盘预配失败（`provision
  failed`）、磁盘创建失败、非预期虚拟机退出（用户未要求关机时的非零退出码或信号）与空闲指示器“SteamOS 无响应…”；
- SIGTERM/SIGINT/SIGHUP 退出的虚拟机（注销、`kill`、处理器安装前的 ^C）不是崩溃：只有日志行，无事件、无报告问题窗口。SIGPIPE 也不是（两进程都忽略：输出管道关闭——终端，或监管器被杀后的监管器 stderr 通道——只失败该次写；虚拟机进程转而记到
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` 或丢弃这些行，让客户机继续关完；STEAMAC-10）。SIGKILL 生成
  warning 级 `vm-killed` 事件，“VM process killed (SIGKILL — memory pressure or force quit)”：
  内核是否因内存杀它（jetsam，监管器 kqueue 的 `NOTE_EXIT_DETAIL`）、
  虚拟机内存与退出/峰值时虚拟机进程 footprint、宿主 `vm_stat` 数（free/compressed/wired、
  swap）、`kern.memorystatus_level` 与启动以来内存压力等级历史
  （变化亦写入日志：`memory pressure: …`）。应用菜单强制退出是请求退出，不报告；
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
在设置 `SENTRY_AUTH_TOKEN`、`SENTRY_ORG`、`SENTRY_PROJECT` 时用 `sentry-cli --url https://sentry.fxgam.es debug-files upload`
上传它们与应用二进制，否则记录跳过上传。

## 更新检查

应用启动时（每次启动一次而非每次虚拟机重启，且至多 6 小时一次——跨启动累计），启动器后台请求最新 release，不阻塞启动，
地址 `https://api.github.com/repos/fxgl/steamac/releases/latest`（匿名，10 秒超时；排除草稿与预发布），比较其 `vX.Y[.Z]` 标签与自身版本
（`CFBundleShortVersionString`，数字比较：1.3.10 > 1.3.9）。有新版本时，在虚拟机窗口旁边（屏幕有空间则不压住；不抢焦点——键盘与捕获鼠标留给虚拟机）出现窗口：“FX Steam Launcher X.Y 已发布 — 当前版本为 …”，
附 release 说明与按钮 **下载**（浏览器打开 release 的 `.dmg`，否则打开 release 页）、**跳过此版本**（启动时不再提示该版本）、
**稍后提醒**（下次检查再提示）。应用菜单 **检查更新…**
项（可用版本未被跳过时显示“有可用更新：X.Y…”带 新 角标，
打开此窗口）立即检查——无 6 小时限制且含已跳过版本——
报告“已是最新版本”或错误；启动时网络与 HTTP 错误只记日志
（`update: …`）。设置 → 通用中 **启动时检查更新**复选框可关（立即生效）。开发版启动器 `work/out/steamac-vm` 启动时不检查（菜单可用）；源码构建（`bundle.sh`）与 release 会检查。

隐私：请求只发 `api.github.com`（GitHub），只带 `User-Agent:
FXSteamLauncher/<version>`（加标准 HTTP 头与上次应答 ETag，以便 GitHub 回“未修改”）；无 Mac 或用户标识、cookie 或 Sentry。检查时间、ETag、应答与跳过版本存于设置（`updateLastCheck`、`updateETag`、`updateCachedBody`、
`updateCachedURL`、`updateSkippedVersion`）。

测试：`STEAMAC_UPDATE_URL` 覆盖 URL（release JSON 或 `/releases` 数组，`http(s)://` 或
`file://`；同时为开发版启动器启用启动检查），`STEAMAC_FAKE_VERSION` 覆盖启动器版本；FIFO `--control-fifo`：`update check|startup|state`、`update press
download|skip|later|ok|releases`、`update dump PNG`（窗口与 `-with-vm.png`——与虚拟机窗口同屏）。

## 报告问题

遇到问题直接从启动器向开发者报告：
**帮助 → 报告问题…**（或应用菜单）、设置 → 通用中**报告问题…**按钮、“SteamOS 无响应…”卡片上**报告…**链接，以及虚拟机非预期退出（崩溃、错误）后出现的
“FX Steam Launcher 意外停止”窗口中的**报告…**按钮。对话框含：
电子邮件（必填，在本 Mac 记住以便开发者回复）、描述（做了什么、期望什么、实际发生什么）与附件复选框：

- **包含启动器日志**（默认勾）——本次会话启动器、libkrun、virglrenderer 与 MoltenVK
  消息（最近约 2 MB，两进程）与 `perf:`/`stall:` 行；路径 `/Users/<name>` → `~`，
  用户名、电脑名、邮箱与 IP 脱敏；
- **包含 SteamOS 日志（系统日志、Steam/Proton 日志）**（默认勾）——本会话客户机控制台（hvc0）与客户机代理收集的 `steamos-logs.tar.gz`：本次启动 systemd journal
  （`journalctl -b`，最近 5000 行，加用户 journal）、`coredumpctl list`/`info`、
  `dmesg`、`systemctl --failed`、`os-release`、`layer-release`、`/proc/cmdline`、`df`/`free`、Steam
  客户端日志尾（`console_log`、`stderr`、`bootstrap_log`、`compat_log`、`connection_log`、
  `webhelper`、`cef_log`、`shader_log`、`steamui_*`）与 Proton 日志（`PROTON_LOG=1` 的 `~/steam-*.log`、
  `compatdata` 中 prefix 的 `version` 与 `config_info`），FEX 工具构建 ID / Steam 清单 /
  配置、可选 FEX 日志、内存限制与 American Truck
  Simulator `game.log.txt` 最近 512 KiB。ATS 模拟器崩溃请将其 Steam 启动选项设为
  `FEX_SILENTLOG=0 FEX_OUTPUTLOG=/home/steamos/fex-amtrucks.log %command%`，复现后报告；
  收集器收录该日志最近 512 KiB。事后移除启动选项。
  FEX 从 JIT 代码重抛模拟游戏的崩溃，core 堆栈只有匿名 AArch64 地址。要记录 x86_64 代码 fault 位置，把游戏启动选项设为
  `LD_PRELOAD=/usr/lib/steamac/x86_64/fault-report.so:$LD_PRELOAD %command%`，复现后报告。
  SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT 时该库把 x86_64 RIP、fault 地址、
  寄存器、每帧模块与偏移的回溯与内存映射写入
  `~/.local/state/steamac/fault-report.txt`。文件不超过 256 KiB，报告以
  `fex/fault-report.txt` 收录。之后游戏自家处理器或默认动作照常，崩溃与其 core dump 不变。不加启动选项则库永不加载。
  完整崩溃元数据由 root 钩子仅导出给 `steamos`（root 所有，0640 模式）；
  原始 core 保持私密从不附加。`coredump-pending.txt` 标识仍在生成的转储：
  报告不等它们；完成后另发一份报告。命名空间感知堆栈提取在有符号处解析 pressure-vessel 库（FEX JIT 代码可能仍无符号）。Core 处理限制不降低：超大 core 会丢回溯，`Storage=none` 仍写完整临时 core。Steam ID（`[U:1:…]`、
  7656119…）、Steam 账号/昵称与邮箱打包前替换为占位符；`collect-notes.txt` 列出可读内容。经 SSH，同份脱敏归档可用
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

## 如何工作

| 目录 | 内容 |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + 补丁：depth_clip_enable、YCbCr 数组、null 描述符、zink/DXVK 用几何着色器模拟（顶点步长、实例化、邻接、扇、SCALED 格式、`gl_in`）、transform feedback（DXVK 流输出）与其查询（SO 统计）、拷贝时查询结果可用（经 Venus 的 DXVK 遮挡查询）、缓冲地址向量分量原子（BDA，vkd3d-proton）、任意 texel 偏移 texel 缓冲（vkd3d-proton）、robustness2 小推导描述符缓冲写入、可变计数描述符数组做运行时数组（Metal 给 vkd3d-proton 每堆数组留 32 MB 与程序）、辅助缓冲分配、Metal 资源延迟释放、管线缓存 UUID 中补丁哈希、绑定中的 `VK_NULL_HANDLE` 描述符集、片元输出转换为颜色附件的数值类型；`repro/` 测试跑在 Metal validation 下（KosmicKrisp 也可：`REPRO_DRIVER=kosmickrisp`）；`bench/run.sh <libdir>…` 比较构建间性能；`bench/shaders.sh <dump or pack>` 从 MoltenVK 着色器转储或 `bench/pack.py` 制作的 10% 采样度量游戏着色器编译（SPIR-V → MSL、MSL → Metal 库、管线状态；冷/热、多线程） |
| `host/kosmickrisp/` | KosmicKrisp（Mesa 主线 @ce576c29）+ 未合并 Mesa MR 与 steamac 补丁（见“Vulkan 驱动”），运行时无 LLVM（`-Dllvm=disabled`，`mesa_clc` 来自首构建），`-Db_ndebug=true`；仅 macOS 26+ |
| `host/libepoxy/` | libepoxy 1.5.10，上游 macOS Meson 选项，为 macOS 15.0 而非拷贝 Homebrew 瓶构建 |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + 合并上游主线（venus-protocol 1.1.3）+ LINEAR 修饰符、shm 按宿主内存导入、失败管线桩（virglrenderer 中丢弃绘制）、拒绝缓存重建、延迟 shm 解映射、线程 QoS、运行时打开 Vulkan 驱动（`VKR_VULKAN_DRIVER`） |
| `host/libkrun/` | libkrun v1.19.6 + 补丁：`VIRTIO_GPU_F_BLOB_ALIGNMENT`（16K）、M4 SME 掩码、无 virgl 的 2D 资源、`SET_SCANOUT_BLOB`、SHM blob 映射、Venus fence 信令、virglrenderer 日志、`krun_display_resize`（运行时改分辨率）、vCPU/GPU 线程 QoS |
| `host/launcher/` | `steamac-vm`（Swift/AppKit）：Metal 窗口（可选 MetalFX 超分辨率）、带开关机进度的“FX STEAM LAUNCHER”覆盖层、客户机分辨率 = 窗口大小（Retina 分辨率下 × 屏幕 backing scale）恒定 DPI（EDID 取自屏幕物理尺寸）、键盘/鼠标/平板、GameController.framework 的客户机 Xbox 360 / DualSense / DualShock 4 手柄带振动或 DualSense 裸 HID 直通（`fx.pad`）、gvproxy 网络、客户机重启则虚拟机重启、`--perf-stats` |
| `guest/kernel/` | Linux 7.2.9，全编入，4K 页，16K blob 节点对齐，FEX 用 Apple TSO；直通 DualSense 用的 uhid、hidraw 与 `hid-playstation`（含其所需 LED 类） |
| `guest/mesa/` | Venus ICD aarch64 版（Proton、gamescope、zink）与 x86_64/i386 版（FEX 图形提供方）；模拟游戏 x86_64 fault 上报器（`/usr/lib/steamac/x86_64/fault-report.so`） |
| `guest/initramfs/` | 启动阶段 = “bootloader”：带尝试计数的 A/B 槽选择、partsets、`/etc` 与 `/usr` 覆盖；启动器创建磁盘的初始预配（`steamac.provision=1`：initramfs 中静态 mkfs.fat、mke2fs、btrfstune）；`steamac.ssh=0`——无 SSH 服务器；启动器配置载荷（`steamac.config=1`）——新 `steamos` 密码；`steamac.tz=`——`/etc/localtime` 中的 Mac 时区；Flatpak 沙箱用 untouched procfs `/run/steamac/proc` |
| `guest/layer/` | `/usr` 上虚拟机层（只读 erofs）：文件化 `splctl`、RAUC 安全 post-install、`VARIANT_ID=steamdeck`、DRM 上 gamescope 会话、桌面模式（gamescope 嵌套 Plasma）、Frame 硬件服务屏蔽、`fx-progress-agent` 进度代理（Rust，`guest/progress-agent/`，`fx.progress` virtio-console 端口）与其 root 服务（`fx.clock`、`fx.sleep`、`fx.pad` 上 uinput 或 uhid 手柄）、短关机超时、二维码 Steam 登录模式（无记住账号时用 Steam Deck 客户端）、可选 Steam 客户端分支（`/etc/steamac/steam-client-branch`）、Steam Shader Pre-Caching 默认关闭（`steam-shader-defaults`） |
| `scripts/` | 构建 `work/out/steamos.img`：Valve 分区布局的 GPT（esp、efi-A/B、rootfs-A/B、var-A/B、home）；`scripts/test/provision-test-disk.sh`——对照 Docker 磁盘的预配开发测试；`scripts/test/vkd3d-tiled.sh`——在临时虚拟机中端到端检查 D3D12 平铺资源与功能级别（Proton 11.0 的 vkd3d-proton 测试、`d3d12-caps`、`vk-minmax`） |

MoltenVK 还修复空 SPIR-V 块中 discard 的 fragment 辅助函数
（STEAMAC-1Q）。`host/moltenvk/repro/msl_helpers.c` 检查直接与嵌套辅助函数：
丢弃像素保持透明且不写存储缓冲；存活像素正常渲染。
它把用户定义的 `log10(float)` 辅助函数改名以避开 Metal 内建重载（STEAM-1R）；
同一复现读回计算辅助函数结果，而非只看管线创建成功。

提交命令缓冲时，`vkCmdBindDescriptorSets` 的描述符集中有 `VK_NULL_HANDLE`
（图形管线库允许）不再导致虚拟机崩溃（Counter-Strike 2 绑定五个集，第四个为空，STEAMAC-25）：
与 RADV 一样，空集不绑定任何内容，也不占用动态偏移（`repro/invalid_usage.c`）。

片元输出的数值类型与颜色附件不一致时，Metal 原先会编译失败，管线绘制被跳过
（DXVK 的一条 Left 4 Dead 2 管线把无符号输出写到 `R32_SINT` 附件，STEAMAC-2C；
Vulkan 未定义这些值）。现在改用附件类型声明输出，写入其位模式（`repro/frag_output.c`）。

SteamOS 根文件系统不动：所有改动来自 initramfs 与层。因此
官方 Valve 更新（RAUC + atomupd）装进另一槽并正常回滚——已用 20260922 → 20260928 更新与回滚验证。

## 状态

已验证：

- SteamOS 启动到 `graphical.target`，自动登录，gamescope 会话；联网（经 gvproxy DHCP、
  下载 583 MB Steam 客户端更新）、SSH；
- 客户机 Venus：`Virtio-GPU Venus (Apple M4 Max)`，Vulkan 1.4；渲染测试（计算 + 清除/拷贝）
  与 KMS 显示输出逐像素匹配基准；
- Proton 11 / DXVK 3.x 所需 DXVK 特性在客户机全部可见（geometryShader、
  shaderCullDistance、depthClipEnable、robustness2 + nullDescriptor、maintenance5/6、…）；
- 键盘、平板、鼠标与虚拟手柄在 SteamOS 可见；DualSense 形态下 Steam 的 SDL
  映射为 `PS5 Controller`（PS5 类型）并显示 PlayStation 图标；手柄随虚拟机运行出现、消失
  与变种；SDL 与 Steam 虚拟手柄的振动到达启动器
  （`rumble 49152 16384` 持续 1.5 秒后归零）；物理手柄上的播放尚未验证；
- DualSense 直通客户机侧：uhid DualSense 带真实 USB 报告描述符，由启动器替身馈送，绑定 `hid-playstation`（手柄、触摸板、体感、耳机孔、
  RGB 与玩家 LED）；触摸位置与触摸板点按到达触摸板设备，静音键经回 Mac 侧的输出报告切换静音 LED，Steam 以 HIDAPI 驱动打开
  `/dev/hidraw*`（`Controller using HIDAPI driver, vid=0x054c, pid=0x0ce6`）。
  Mac 侧（IOHIDManager，USB 或蓝牙物理 DualSense）尚未验证；
- 桌面模式：切换到桌面、带鼠标输入的 Plasma 桌面（含黑边）、返回游戏模式、直启桌面；Flatpak 沙箱可启动；
- 官方 OTA A→B 更新与回滚；
- zink 的 GL（Xwayland 中 glamor，glxgears ~60 FPS）、Steam UI（手柄 UI，GPU CEF）
  在虚拟机窗口渲染；
- Steam 登录、Proton 11.0-2（ARM64）与 FEX 安装、DX11 游戏（Death's Door）
  经 DXVK → Venus → MoltenVK 运行；
- 客户机分辨率恒定 DPI 跟随窗口大小；快速关机（2–4 秒）；
- Heroes of Might and Magic: Olden Era（Unity，DX11）——7 分钟无错误（离线测试）。

首遍卡顿是 Metal 编译（每新管线约 50–100 ms）；之后约 1 ms。异常关机后重启，initramfs 检查并修复 esp/efi 的 FAT。

## 限制

- DirectX 12（vkd3d-proton）：KosmicKrisp 支持功能级别 12_0（Tiled Resources Tier 2：基于 Metal 4
  placement sparse resources 的稀疏绑定与驻留），MoltenVK 为 11_0；两者均为 SM 6.0（Apple GPU 不支持 SM 6.2+）。
  同一渲染通道内，写入稀疏深度附件未绑定图块的深度仍保留在 Apple 的图块内存中。
  Stellar Blade 试玩版（UE4）在 M4 Max 上以 1280×800 达到 60 FPS；首次运行需数分钟编译着色器。
  Proton ARM64 中的 x86 模拟器（FEX）曾在 20 分钟后因其受保护 .exe 的 DEP 检查停止运行。
- 音频：virtio-snd → CoreAudio（默认设备或设置中所选），内置扬声器延迟约 65 ms；麦克风已通告但未经测试。
- 屏蔽虚拟机的反作弊不可用。
- `logicOp` 不可用（MoltenVK 分支中私有 Metal API 编不过）；zink 报警告。

## 许可证

项目代码采用 Apache License 2.0（`LICENSE`），© 2026 FX GAMES FZ LLC。例外见
`NOTICE`：Linux 内核补丁与配置——仅 GPL-2.0，virglrenderer 与 Mesa
补丁——MIT（如这些项目），五个源自 Valve
`deckard-steamvr-session` 包的 gamescope 会话文件——MIT © Valve Corporation；Valve CA 证书与
`docs/media` 截图不在项目许可范围内。许可文本在 `LICENSES/`。

SteamOS 非项目组成部分，也不随项目分发：应用在用户接受 Valve 许可后从 Valve 服务器下载签名映像
（见“无需 Docker 创建 SteamOS 磁盘”）。

Steam、Steam 标志、SteamOS、Steam Deck 与 Steam Frame 是 Valve Corporation 在美国和/或其他国家的商标和/或注册商标。本项目与 Valve Corporation 无关，也未经其背书。
