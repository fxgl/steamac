# 从源码构建

[English](../building.md) · [Русский](../ru/building.md) · **简体中文**

← [手册](README.md)

## 要求

- Apple Silicon Mac，macOS 15+，约 150 GB 可用空间（磁盘映像为稀疏文件）。
  启动器需要 Mac 本机的 Hypervisor.framework：在 macOS 虚拟机内（Paravirtual GPU、`kern.hv_vmm_present`）或没有 `kern.hv_support` 时，它会说明原因并在启动虚拟机前退出，而不是上报 libkrun 的 `krun_start_enter failed: -22`（STEAMAC-15）。
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
./build.sh          # Vulkan 栈：MoltenVK、virglrenderer、libkrun、启动器、内核、Mesa、磁盘
./build.sh dxmt     # DXMT + wmtr 宿主执行器和客户机载荷；随后重建层与启动器（见下文）
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

游戏模式默认以虚拟显示器的原生分辨率渲染 Steam UI（包括 Retina），而不是 Steam 单独的
1920 × 1080 UI 上限。Steam 启动前，`/usr/lib/steamac/steam-native-resolution` 在 `config.vdf`
中补充缺失的 `InstallConfigStore/Gamescope/EnableSteamNativeExternalResolution` 值，
每个 Steam 安装只处理一次（标记 `config/steamac-native-resolution`）。已有值和之后在 Steam
中的选择均保留，即使 Steam 删除该键也不会重新应用默认值。已有的 1080p 上限需要重新启动
gamescope 会话（重启虚拟机）才能解除；只重启 Steam 不够。全局游戏分辨率设置单独控制游戏，
在那里选择 5120 × 2880 不会提高 Steam UI 分辨率。保持 `Default` 的游戏会跟随 UI，因此为避免增加游戏默认 GPU 开销，
每个账号缺失或为 `Default` 的全局游戏分辨率会先设为原有上限（1920 × 1080，16:10 为 1920 × 1200；
较小显示器保留其首选模式），并且只有在至少处理过一个账号后才启用原生 UI：Steam 在运行时创建账号配置并
把它保存在内存中，所以只能在两次 Steam 运行之间修改。因此全新安装时，原生 UI 从首次登录之后的那次 Steam
启动开始启用（并在其后的新 gamescope 会话中生效）。该上限跟随显示器：每次 Steam 启动时，只要账号仍恰好是启动器写入的值
（`userdata/<account>/config/steamac-native-resolution` 记着它），就会按当前显示器重新计算。明确的全局设置（包括 `Native`）、
单个游戏覆盖值以及之后修改的任何值（包括删除该键）都会保留，不再跟随或重新应用。无法读取或写入的配置会被跳过并记入日志，
其他账号仍会处理。在已运行原生 UI 的会话中首次登录的账号，会在下一次 Steam 启动时获得上限。启动器每边最多 4094 像素的限制仍适用。

虚拟机中 Steam 空闲屏保（游戏模式下 设置 → 显示 → 屏幕保护程序）默认关闭。数分钟无输入后，Steam 会把
`Screensaver_uid<n>` 窗口放到正在运行的游戏前面，gamescope 把焦点移给它，之后的点击都进入 Steam，直到按
Escape。启动器的鼠标、数位板与键盘会重置 Steam 的计时，但长时间停在加载画面的游戏或 VR 中的游戏（头显输入
不会到达 Steam）对 Steam 而言就是空闲；macOS 有自己的屏保与显示器睡眠。Steam 启动前，
`/usr/lib/steamac/steam-idle-screensaver`（`steam.service` 的 ExecStartPre）在缺失时写入
`"IdleScreensaverACSeconds" "0"` 与 `"IdleScreensaverBatterySeconds" "0"`（`config.vdf` 中的
`InstallConfigStore/Software/Valve/Steam/System`；0 = 从不），每个 Steam 安装只写一次（标记
`config/steamac-idle-screensaver`），因此之后在 Steam 设置中选择的屏保时间会被保留。

游戏需要驱动提供的环境变量是默认值，而不是代码：`/usr/lib/steamac/steam-title-defaults`（同样是
`steam.service` 的 ExecStartPre）在游戏的 Steam 启动选项（`%command%`）前加上所需的 `VAR=value`。
目前只有一项：Dragon's Dogma 2（2054970）要求 D3D 功能级别 12_1，vkd3d-proton 根据 ROV 和
conservative rasterization 推出该级别——Metal 两者都没有（conservative rasterization 在 Metal 中没有
API；ROV 需要把 Metal 的 raster order groups 映射为 `VK_EXT_fragment_shader_interlock`），而该游戏只检查
级别，因此报告为 `VKD3D_FEATURE_LEVEL=12_1 VKD3D_SHADER_MODEL=6_6`，同时带上
`VKD3D_DISABLE_EXTENSIONS=`（空）。KosmicKrisp 的 64 位原子操作只有无符号 min/max，所以
`steam.service` 默认对所有 D3D12 游戏隐藏 `VK_KHR_shader_atomic_int64` 和
`VK_EXT_shader_image_atomic_int64`（其 drop-in 中的 `Environment=VKD3D_DISABLE_EXTENSIONS=…`；着色器使用
其他 64 位原子操作的游戏会悄悄丢失这些管线，而 vkd3d-proton 据此报告 shader model 6.6），合适的游戏
通过自己的启动选项重新启用。该默认值是 Steam 继承的环境，而不是 `gfx.txt` 中的一行：
`steam-launch-wrapper` 先后把 `$XDG_RUNTIME_DIR/steam/env/gfx.txt` 和 `~/.config/steam/env/gfx.txt`
中的所有变量覆盖到游戏环境上（包括启动选项），所以写在那里的 `VKD3D_DISABLE_EXTENSIONS` 对所有游戏
生效。条目仅在 Venus 设备公布其所需功能时应用（DD2：64 位原子操作，Apple8/M2 及更新），如果之后某次
启动 Steam 时这些功能消失（驱动切换为 MoltenVK、磁盘移到 M1），则撤回并恢复原来的启动选项；探测失败
时不做任何改动。已有的值只在前面追加、不会被替换，不含 `%command%` 的值不受影响，用户之后在 Steam
中的修改优先（标记 `~/.config/steamac/title-defaults.json`，其中也保存原值）。
配置中的 `env` 会覆盖内置条目；没有此覆盖时，DD2 仍保留受 Venus 功能检查约束的默认值。

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
每次检查在同一时刻取 GPU 空闲时间与心跳时长，因此被 Mac 自身延迟（换页、主线程繁忙）的检查不会只让心跳“变老”而报告无响应（STEAMAC-8）。
“回收磁盘空间”的确认、错误与结果对话框改为表单或独立窗口，不再以模态循环阻塞（接收心跳的）主队列（STEAMAC-8）。

| 窗口中的按键 | |
|---|---|
| Ctrl+Cmd+F | 全屏（macOS 开启游戏模式：Info.plist 声明为游戏——`LSApplicationCategoryType` `public.app-category.games`、`GCSupportsGameMode`、`LSSupportsGameMode`；`gamepolicyd` 记录 “Game mode status is now on”） |
| Ctrl+Cmd+G | 手动捕获 / 释放鼠标 |
| Ctrl+Cmd+P | Apple Metal 性能 HUD 开关（FPS、帧间隔、GPU 时间、内存）；另见 显示 → 显示 Metal 性能 HUD（Ctrl+Cmd+P） 与 设置 > 显示。只有虚拟机启动时 HUD 已开启才会加载其库：开启需重启后生效，关闭会立即隐藏，并在下次重启时卸载。Apple 的 HUD 曾在 macOS 26 上使用 KosmicKrisp（Metal 4）时导致虚拟机崩溃，即使覆盖层已隐藏（STEAMAC-59/7K/7Q/9X/9Y），因此在使用 KosmicKrisp 时开启 HUD 会要求确认；不使用 Apple HUD 的替代方式是 设置 > 通用 > 记录帧节奏统计，记录客户机显示时序（不是游戏 FPS）。崩溃报告包含请求与实际生效的 HUD 状态、是否注入了 HUD 库以及驱动信息 |
| Ctrl+Option | 释放已捕获的鼠标 |
| 关闭窗口 | 关闭客户机（电源键） |

鼠标（`--mouse auto`，默认）：SteamOS 光标精确跟随 Mac 光标，画面上方的 Mac 光标被隐藏，只显示 gamescope 的光标（在黑边、可点按的进度条和 "Report…" 链接、菜单和其他窗口上方，启动、暂停或睡眠期间，以及窗口之外，Mac 光标会重新出现）。gamescope
（游戏模式）不接受绝对坐标，启动器用无加速相对位移驱动它，单位是 gamescope 所显示表面的像素：代理在每条焦点消息中附带其尺寸（Steam 设置 > 显示 > 分辨率不是原生分辨率时为 `focus steam 1920x1200`，界面小于显示器并被放大），启动器按 gamescope 将其缩放进显示器的方式把窗口映射到该表面（`--selftest-pointer`）。当客户机中游戏获得焦点（代理发送 `focus game <appid> <w>x<h>`），
首次点按捕获鼠标（视角用相对移动）；Ctrl+Option 释放。回到 Steam 时自动解除捕获。**鼠标**菜单：
- **在此游戏中捕获鼠标** — 当前游戏自动捕获（按 appid 保存）；
- **在游戏中自动捕获鼠标** — 所有游戏默认；
- **立即捕获或释放鼠标（Ctrl+Cmd+G）** — 同 Ctrl+Cmd+G。

这些与所有其他设置都在[**设置**窗口](settings.md#设置窗口)，域为
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

外接 APFS、Mac OS 扩展与 exFAT 卷可存放磁盘，推荐 APFS；NTFS、网络文件系统和未知文件系统驱动在下载前即被拒绝（STEAMAC-8S：NTFS 驱动在下载一小时后以“File too large”拒绝了 92 GB 的磁盘），下载后才出现的文件大小限制会向用户说明并只记日志，不发送到 Sentry。FAT32/MS-DOS 因 4 GiB 单文件限制在下载前拒绝
（临时 rootfs 就 10 GiB）。只读卷和没有写入权限的文件夹同样会被拒绝。与 APFS 不同，exFAT 无稀疏文件：即使游戏还没装，也需要所选磁盘全尺寸加临时 rootfs 的空间。下载缓存在 exFAT 上也远超其约 4.4 GB 的数据：macOS 把每个分块文件的来源（provenance）属性存进额外的 `._` 文件，且每个文件和文件夹都占用整簇（2 TB 盘上为 128 KiB），合计约 28 GB。启动器先检查空间再重建 rootfs；在 exFAT 上，若卷空间不足，会在分配磁盘前删除分块缓存（`--keep-cache` 保留缓存，需要两者的空间）。
预期存储错误（目标已存在、缓存正被使用、只读卷、没有写入权限、空间耗尽、磁盘断开、创建过程中磁盘或缓存文件夹消失或文件系统 I/O 错误）
会显示处理建议并只记日志，不作为错误发送到 Sentry；创建开始后的错误也遵循此规则。元数据/包下载的网络错误
（离线、DNS、超时、连接中断和系统 TLS 验证拒绝）与 desync 重试耗尽一样处理，包括读取分块 HTTP 响应正文时超时（STEAMAC-92），绝不绕过 HTTPS 证书验证。若 desync 无法把分块存入缓存（exFAT 缓存上的 `invalid argument`，STEAMAC-90/91），日志会记录出错缓存分片的状态（模式、条目与临时文件数、读取错误）以便诊断。
不是 JSON 的元数据响应（空、截断、门户或代理的 HTML 页面）与 HTTP 拒绝同样处理，并在日志中记录 HTTP 状态、Content-Type、长度和前 160 字节（STEAMAC-AQ：`stable.json` 的 `NSCocoaErrorDomain 3840`）；JSON 合法但结构不兼容时仍会上报。
非预期创建错误和包签名错误仍会上报，事件详情保留原始诊断。若内置的 desync 缺失、不可读或不可执行（STEAMAC-8K），窗口会说明安装不完整：请从官方 DMG 重新安装到“应用程序”，并检查安全软件。每次安装只发送一条警告，记录 translocation、desync 的存在与权限、代码签名结果以及 Resources 中相对于包的文件名与大小；包的绝对路径只留在本地日志中，不打开崩溃报告对话框。
警告还记录应用包、`Contents` 和 `Resources` 是否仍然存在（类型和 errno）：应用在运行时被移动、删除或替换会让三者全部消失（STEAMAC-AE），因此建议在替换或移动前完全退出 FX Steam Launcher，然后从“应用程序”重新打开。
启动器记录目标和缓存的文件系统类型。缓存分块重命名冲突时，以单工作线程、不使用缓存重试一次。
rootfs 哈希不符时再顺序读取，以区分错误的稀疏区段元数据和文件字节损坏；若字节损坏，则删除临时 rootfs 与分块缓存，
以单工作线程、不使用缓存重新下载一次，重试前清空两个磁盘槽。再次校验失败仍会上报；哈希不匹配签名清单就不发布磁盘。报告会记录顺序 SHA-256，以及源数据重读与 rootfs-A 首个不同的 1 MiB 块（偏移量与两个块的摘要），以区分读取不稳定与复制错误（STEAMAC-9F/9H）。
创建磁盘时会把读回的分区表与写入内容比对——在私有文件中以及磁盘发布之后各一次。若不一致（STEAMAC-6J，exFAT），
或重建的 rootfs 在分配磁盘前消失（STEAMAC-68），仍会上报，并附文件标识与不一致的 GPT 字段；窗口建议用“磁盘工具”的“急救”检查驱动器或换一个驱动器。

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
   （外接盘则内部不占缓存空间；成功后删除该目录）。故停止/创建（或 Ctrl+C 后重跑命令）可断点续传；之前某次在后续步骤失败而留下的完整 `<disk>.rootfs-tmp` 会先被删除（desync 不会复用它，保留只会让它占用两倍空间）。一个缓存一次只允许一次创建：第二次（另一窗口或 `--create-disk`）以“另一个 SteamOS 磁盘正在使用下载缓存 … 创建：请等待创建完成或取消该操作”停止（缓存目录中 `creation.lock` 的 `flock`），而非共享块缓存与临时文件。
4. 稀疏磁盘文件：保护 MBR + GPT（主备，CRC32），名称、顺序、类型、大小与对齐与 `scripts/steps/40-disk.sh` 完全一致，PARTUUID 随机。一遍写入中，对 `rootfs.img` 哈希（sha256 须与签名 manifest 一致），16
   KiB 非零块写入 rootfs-A 与 rootfs-B；其余分区写零。全部检查通过后磁盘才以最终名称出现。已存在文件从不覆盖；exFAT
   无原子独占改名，启动器持创建锁检查目标后再改名。创建期间勿用非启动器程序向同一目标创建或移动其他文件：该检查与改名对它非原子。
5. 旁边放置 `<disk without .img>.provision.img`——cpio newc，内含
   `provision.env`（构建、PARTUUID、SHA-512 crypt 密码哈希、machine-id）与 `rootfs.caibx`
   （格式见预配契约“Payload v1”）。该文件存在期间，启动器只读挂载它（vdc）并加 `steamac.provision=1`：initramfs 格式化
   esp/efi-X/var-X/home，使 rootfs-B fsid 唯一，写入 partsets/bootconf/bootenv/var，
   并上报 `provision done`——之后启动器删除载荷；后续启动不再使用。

支持稀疏文件的卷：创建期间磁盘卷约 20 GB（成功后约 9 GB），另加约 6 GB 缓存。macOS 上的 desync 即使在 APFS 上也会预分配完整的 10 GiB 临时 rootfs；只有目标的两个槽保持稀疏。
空间预检包含此分配和安全余量（SteamOS 20261007 共约 27 GB）。除非 `--keep-cache`，成功后删除缓存。检查：`work/out/steamac-vm --selftest-provision`——
GPT 对 Docker 构建磁盘（`work/out/steamos.img` 只读打开；
`--reference-disk IMG`），CMS/squashfs 对 `work/cache/rootfs` 缓存，cpio、SHA-512 crypt。
自测还检查网络提示、网络/文件系统预期错误只记日志、非预期错误仍上报，以及稀疏/顺序读取 rootfs 后两个槽的内容。
要在不发送任何事件的情况下触发真实 TLS 失败，运行 `--selftest-provision` 时将
`STEAMAC_PROVISION_TEST_TLS_URL=https://localhost:PORT/` 指向使用不受信任证书的本地服务器；
它会打印提示并检查不会产生报告。

## 分发（DMG）

`host/launcher/dist.sh` 把构建好的 `work/out/FX Steam Launcher.app` 做成可下载的
`work/out/dist/FX-Steam-Launcher-<version>.dmg`（应用 + `/Applications` 链接）。去掉 `SteamacBuildOut` 键（本构建树路径）的包拷贝用 Developer ID
重签，hardened runtime，安全时间戳，由内向外：先签全部独立内嵌 Mach-O（`Frameworks/*.dylib`、`Resources` 中辅助程序、Sparkle 的 `Autoupdate`），
再由深到浅签内嵌包（Sparkle 的 `Updater.app`、`Sparkle.framework`），最后用 `steamac-vm.entitlements` 签包（hypervisor、
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

应用内更新（[更新检查](privacy-and-updates.md#更新检查)）：`dist.sh` 写入 `SUFeedURL`（`SPARKLE_FEED_URL`，默认
`https://fxgl.github.io/steamac/appcast.xml`）、`SUPublicEDKey`（`SPARKLE_PUBLIC_KEY`，默认为 `dist.sh` 中固定的 fxgl 发布密钥
`ML1BKHcTTwKlVSLtTdMvyk7Fhwg35VN1nUp+o4fezt8=`：已安装的副本只接受它签名的更新）、
`SUVerifyUpdateBeforeExtraction` 与 `SURequireSignedFeed`；钥匙串中没有该密钥的私钥时，公证构建失败（`generate_keys -p` 打印其公钥）。
EdDSA 密钥对已用 `host/launcher/.build/artifacts/sparkle/Sparkle/bin/generate_keys` 创建一次（Sparkle 工具随 SwiftPM 包提供，
与内嵌框架同版本）；私钥留在登录钥匙串，绝不进仓库或 CI。请离线备份（`generate_keys -x <file>`；另一台 Mac 用
`generate_keys -f <file>` 导入）：丢失后已安装的副本再也收不到更新。`build.sh` 令 `CFBundleVersion` 等于
`CFBundleShortVersionString`（Sparkle 按它比较版本）。发布须按此顺序（feed 不得指向尚未上传的文件）：

```sh
host/launcher/dist.sh
gh release create v<version> work/out/dist/FX-Steam-Launcher-<version>.dmg \
    work/out/dist/FX-Steam-Launcher-<version>-gpl-sources.tar --notes-file <notes.md>
host/launcher/appcast.sh    # docs/appcast.xml，增量更新附到 release
git commit -m "appcast: <version>" docs/appcast.xml && git push    # GitHub Pages 发布 feed
```

`appcast.sh` 先确认 release 中的 DMG 就是本地文件（大小相同），再对 `work/out/updates`（旧版本归档；feed 取自
`docs/appcast.xml`）运行 Sparkle 的 `generate_appcast`：新条目含 DMG 的 EdDSA 签名、取自 `LSMinimumSystemVersion` 的最低 macOS、
GitHub release 说明（Markdown，内嵌）与该 release 的下载地址；对 `work/out/updates` 中至多 3 个旧版本 DMG 生成增量更新
（内核与多数辅助程序很少变化），改为不含空格的文件名（GitHub 会改名此类文件）并上传到 release；整个 feed 签名。
其余参数交给 `generate_appcast`，如 `--phased-rollout-interval 86400`（7 天内逐步推送）或 `--critical-update-version ''`。
不要手改 `docs/appcast.xml`：签名覆盖整个文件。本地端到端测试：两个版本各用 `dist.sh --no-notarize`，带
`SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml` 与 `SPARKLE_PUBLIC_KEY=<测试公钥>`，每次之后运行
`SPARKLE_KEY_FILE=<测试私钥> host/launcher/appcast.sh --local http://127.0.0.1:8765`，并在 `work/out/updates-local` 中运行
`python3 -m http.server 8765`。
