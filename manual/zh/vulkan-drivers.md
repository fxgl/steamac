# Vulkan 驱动

[English](../vulkan-drivers.md) · [Русский](../ru/vulkan-drivers.md) · **简体中文**

← [手册](README.md)

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
（不启动虚拟机、不发送 Sentry 事件）。该选择只在 Metal 初始化前进行：之后才变得不可写的缓存无法在运行中的进程里重定向，因此报告附带启动时的决定（`metal_cache` 标签）以及失败的 `monolithic_metal.pcm` 路径的只读元数据（STEAMAC-7W）。MoltenVK 不支持同时含曲面细分与几何着色器的管线：这类管线返回 `VK_ERROR_FEATURE_NOT_PRESENT`，而不是带着无效缓冲绑定编译（STEAMAC-83）。

| 选项 | 是什么 | 利弊 |
|---|---|---|
| **KosmicKrisp** — Mesa on Metal 4 · macOS 26+（`kosmickrisp`，可用时默认） | `host/kosmickrisp/`：Mesa 主线 + 未合并 MR（几何着色器 !44786、transform feedback !44928、宿主指针内存中的平铺图像 !44929、device-local 内存类型 !44221、线性渲染目标 !44782/!44222）+ steamac 补丁（显式 LINEAR 行距、LINEAR 输入附件、DXVK 所需的 `fillModeNonSolid`、8 倍采样请求按 4 倍处理、vkd3d-proton 所需的 texel 缓冲单 texel 对齐与跨多个 Metal 计数器堆的时间戳池；R32G32B32 uniform texel 缓冲——vkd3d-proton 以此格式查看步长 12 字节的结构化缓冲（这样的视图曾在 The Witcher 3 中使 VM 崩溃，STEAMAC-2Z）；所有客户机设备共用一个 Metal 编译器，macOS 27 上也是如此（在其 beta 1–4 上每个设备各用一个编译器会在客户机会话启动时破坏堆，STEAMAC-31）；零元素 texel 缓冲视图成为 null 描述符，过大的视图按对齐前缀之后 Metal 对该格式的容量截断（2^28 个 texel，RGB32 每元素三个），而非保守的通告上限：无效宽度不会进入 Metal，Venus 异步创建错误也不会在首次使用时杀死客户机进程（Spider-Man、Uncharted、Forza Horizon 6、Dragon's Dogma 2，STEAMAC-3J/3F/3S/3R）；基于缓冲的 texel 缓冲视图共用其缓冲的驻留（约 1M 个以上视图曾耗尽驻留集并中止，DOOM、Wolfenstein，STEAMAC-3V/3T）；遮挡查询可超出单个 32768 条目的可见性缓冲，时间戳池使用进程内所有客户机设备共享的计数器堆（Metal 每进程只允许 32 个），因此 Dota 2 / Counter-Strike 2 的查询池不再创建失败；渲染编码器之外的时间戳写入合并 resolve，每 16384 次写入拆分录制，避免 Metal 4 命令缓冲容量不足（Ratchet & Clank: Rift Apart，#45；超过 131072 的写入仍读为 0）；基于 Metal 4 placement sparse resources 的稀疏绑定与驻留，在 Apple10 之前的 GPU 上用着色器模拟采样器 min/max reduction，为 vkd3d-proton 提供 Tiled Resources Tier 2，从而支持 D3D12 功能级别 12_0；编译池仅排队预测会使用的 plain/minmax 程序，另一程序首次使用时编译；depth/stencil 状态在创建时独立于程序选择只构建一次，因此绑定不等待编译；翻译后着色器缓存包含 `force_robustness` 等代码生成设置，已编译 Metal 对象使用有界 LRU 表并在发布时检查所有权） | 更快：M1 Max 上 Stellar Blade 试玩版约 29 FPS，MoltenVK 约 18（分屏视频：`docs/media/stellar-blade-moltenvk-vs-kosmickrisp.mp4`）；Steam UI、DXVK 游戏和 Stellar Blade 试玩版（D3D12，vkd3d-proton）可运行，后者在 M1 Max 上首次运行需约 28 分钟编译着色器。仅 macOS 26+；构建机也必须运行 macOS 26+，否则使用 MoltenVK。已知缺口（宿主复现）：带条带几何着色器的 transform feedback 及其溢出计数器（草案 MR）；同一渲染通道内，对未映射图块的深度写入保留在图块内存中，后续绘制仍会用这些值做深度测试（Tiled Resources Tier 2 允许该缓存；vkd3d-proton 的 `test_sparse_depth_stencil_rendering` 则期望丢弃）；不支持稀疏 3D 纹理（Metal 的 3D 图块不符合 Vulkan 标准 3D 块布局），因此没有 Tiled Resources Tier 3 |
| **MoltenVK** — Metal 3 · macOS 15+（`moltenvk`） | `host/moltenvk/`：UTM 分支 + steamac 补丁 | 所有受支持 Mac；macOS 15 默认，无 KosmicKrisp 的构建也默认（macOS 15 源码构建；1.7 起发布 DMG 含 KosmicKrisp） |

切换改变 Venus 驱动身份（管线缓存 UUID），Steam 与游戏重建着色器缓存。宿主驱动建不出的管线在 virglrenderer 中是占位：其绘制与派发被丢弃，驱动永远见不到 `VK_NULL_HANDLE`。

宿主驱动拒绝会触发 Metal 断言、进而终止整个虚拟机的 Vulkan 输入，并把 Vulkan 参数写入日志。KosmicKrisp：层范围为空或越界、或在块大小不同的颜色格式之间创建的图像视图返回 `VK_ERROR_FORMAT_NOT_SUPPORTED`（STEAMAC-62/3）；着色器使用而管线布局缺少的描述符读为零、写入被丢弃（STEAMAC-6H）；经中转缓冲的图像复制不超出 mip 边界并覆盖体纹理的所有切片（STEAMAC-5E/5F）；mip 级别、层、深度或采样数超出格式查询所报告范围的 LINEAR 图像在 `vkCreateImage` 时被拒绝（STEAMAC-3F/6Y）；缓存的预编译 NIR 着色器附带 BLAKE3，反序列化前先校验，损坏的条目视为缓存未命中而不是崩溃。`vkCreateComputePipelines` 中的 STEAMAC-6M/6K/7J/7H/7P 崩溃另有原因：Mesa 的 NIR 序列化器只用 20 位保存源索引，超过 2^20 个对象的着色器反序列化后，源会指向无关对象；更大的索引现在另用一个字写出（`host/kosmickrisp/test/nir_object_ids.c` 随 KosmicKrisp 构建往返校验一个含一百多万个 def 的着色器）。嵌套超过 128 层的分支改为带已保存条件的并列块输出，因为 Metal 拒绝括号嵌套超过 256 层的源码（STEAMAC-G 报告；`sentry-g-brackets.sh` 在 GPU 上校验 320 路发散分支阶梯）。对可复现的 KosmicKrisp 卡顿，启动 macOS 启动器时（而不是作为游戏参数）设置 `MESA_KK_DEBUG=syncs,cbs`，会追踪队列同步以及每次超过一秒的 CPU 等待（STEAMAC-94）。源缓冲或目标缓冲为 NULL 的缓冲复制会被跳过并仅警告一次，而不是让虚拟机进程崩溃（Dota 2，STEAMAC-9S/9T；`host/kosmickrisp/test/copy-buffer-null.py`）。Mesa 在 macOS 上的屏障回退实现可能让 `util_queue_finish` 在销毁设备（着色器磁盘缓存）时永久挂起；`host/kosmickrisp/test/util_queue_finish.c` 随 KosmicKrisp 构建运行。MoltenVK：对 Metal 无法混合的附件（R32_UINT）启用混合的管线创建失败（STEAMAC-3A）；顶点阶段辅助缓冲打包进 Metal 的 31 个缓冲槽（STEAMAC-67）；支持完整 32 位 specialization constant ID（STEAMAC-6A）；导入宿主内存中的 optimal 图像获得 placement heap，3D 图像的 2D 视图用作渲染附件时不再访问缺失的 heap（STEAMAC-76/77）；管线创建失败时日志记录完整的小型着色器、Metal 描述符、混合状态和片段输出索引（STEAMAC-41/75）；若着色器没有第二个输出，该附件的双源混合因子对它取零（Vulkan 中其值未定义，而 Metal 会拒绝该管线，STEAMAC-75）；在 M1 上，带 sample 限定的透视投影改在 `get_sample_position(sample_id)` 处插值，避开 Metal 缺失的 `llvm.agx2.sample.itrproj` 内建函数（STEAMAC-8J）。SPIRV-Cross 修复 STEAMAC-33/6D/6E/5M/5K/2N/5C/6V 的 MSL 错误，在打包输出时保留双源混合的第二个索引（STEAMAC-75），保留带间隔的接口块成员显式 Location（Location 0 与 2 曾变成 `locn0`/`locn1`），并把 object 着色器负载中的 `locations` 声明为 `uint[32][4]`（布局相同）：Apple 编译器在对 `uint4 locations[32]` 做部分写入时崩溃，表现为内部错误或 XPC 连接中断（STEAMAC-41/R）；编译服务中断的报告附带宿主内存压力与 swap（STEAMAC-3X）。Workgroup（共享内存）数组中的 `vec3` 成员按 Vulkan 填充规则所计的大小紧凑存放，968 个 `{float; vec3; float}` 只需 19360 字节，而不是 Metal 布局下超过 32768 的 46464 字节（STEAMAC-57）。同一 Location 上比片段输入更窄的顶点输出（float3 → float4）会加宽到输入宽度；缺失的 varying 与不同数值类型仍不支持（STEAMAC-2M/88）。名为 `rgb9e5` 的着色器函数会被重命名，以免与 Metal 的 `rgb9e5` 像素类型冲突（STEAMAC-A9）；只写入 `ClipDistance` 的几何/网格阶段也会写入片段着色器读取的 `user(clip0)` 副本（STEAMAC-A2）。`host/moltenvk/repro/sentry-msl.sh` 编译每个重建的着色器。wmtr（DXMT）只拒绝无效或已释放的对象句柄，在游戏上下文消失时结束其未关闭的编码器（包括存活对象超过 65,536 个时，STEAMAC-70），并拒绝没有顶点函数的渲染管线（STEAMAC-6S/6Z）；`wmtr/tests/wmtr_dxmt_test.m` 在 GPU 上通过发布的执行器运行 DXMT 自己的命令列表。

没有顶点着色器的图形管线创建失败（日志记录其阶段），而不是在绑定时使虚拟机进程崩溃（STEAMAC-AH；`REPRO_CASE=sentry-ah host/moltenvk/repro/run.sh`）。单层 2D 图像的视图若层数溢出（Zink 的 `0+65536`），保留这一层，而不是让 GPU 上下文终止；格式不兼容的视图（RGBA8 图像、R8 视图）仍被拒绝，日志记录客户机应用和完整视图参数（STEAMAC-G）。指向上下文所没有资源的回复流仍是致命错误；virglrenderer 记录该资源是已从此上下文分离（及多久之前）、从未附加，还是不是共享内存（`host/virglrenderer/test/reply-resource.py`，STEAMAC-G）。MoltenVK：Red Dead Redemption 2 的 Vulkan 渲染器在 MoltenVK 不提供管线统计查询时仍创建此类查询池；现在它们会被创建并返回零（该特性仍关闭），不再失败并终止 GPU 上下文；超过 4096 个查询的时间戳池使用多个 Metal 采样缓冲；经 CPU 影子副本复制的宿主内存图像使用真实的纹素/块行距（AGX `bytes_per_row` 断言，STEAMAC-AG/G；`REPRO_CASE=sentry-ag`）。在 GPU 上失败的命令缓冲会记录其编码器与着色器。

致命命令与对象查找失败的日志行会标明客户机上下文（编号与进程名），不必再根据相邻的 `destroying context … (explorer.exe)` 行猜测哪个上下文终止；被拒绝的图像视图还会记录实际格式特性和块兼容性（STEAMAC-G：Zink 的 RGBA8 图像上的 R8 视图仍被拒绝）。KosmicKrisp 在创建 Metal 编码器前记录其命令分配器、编码器与上传内存的有界峰值快照（`REPRO_CASE=command-allocator`）；启动器记录实际加载的 Apple Metal 工具库（`metal_instrumentation` 标签：关闭 HUD 时 `libMetalMetricsInterpose` 也可能通过 macOS 帧节奏机制加载），并在虚拟机占用 30 秒内增长超过 8 GiB 时记录一次 VM 标签分解（STEAMAC-AK/AP/AN/AX：占用从 52 GB 跳到 95 GB 后 IOGPU 命令存储分配失败，原因尚不明确）。MoltenVK：Metal 只支持设备内存上的浮点原子操作，工作组（`shared`）内存上的浮点原子操作改用 `atomic_uint` 位转换和比较交换循环模拟（STEAMAC-AS）；几何/曲面细分模拟中的顶点获取按 location 逐个读取数组与矩阵类型的顶点输入并使用各自格式（`half2[2]`，STEAMAC-AV）。

顶点函数在其库中解析不到的渲染管线，会像其他编译失败一样创建失败，并在日志中记录函数名、库中的函数和程序的 MSL 哈希，而不是触发 Metal 的进程中止 `vertexFunction must not be nil`（STEAMAC-BN/BP；`REPRO_CASE=sentry-bn`）。若渲染通道的帧缓冲引用了在通道开始前已销毁的图像视图，会在 Mesa 通用代码访问这个已释放的视图前记录其附件、格式与帧缓冲（STEAMAC-BJ/BK，DOOM 2016：`transition_attachment` 读到该视图的图像为 NULL；尚不清楚由谁销毁；`REPRO_CASE=sentry-bj`）。MoltenVK 在为其他变量匹配向量宽度时，仍保持带不同 Component 的顶点输出及对应片元输入彼此独立，修复了 1.9.14 中重复 `locnN`／顶点函数返回类型无效的回归（STEAMAC-87/BB；`REPRO_CASE=sentry-87-components`，像素测试覆盖普通声明、接口块、两个方向的宽度调整以及序列化管线缓存的重用）。

**允许 DXMT（通过 Mac 的 Metal 运行 D3D11），实验性。** 设置 → 高级 →
**允许 DXMT（通过 Mac 的 Metal 运行 D3D11）**默认关闭，下次启动生效（单次启动用 `--wmtr-lib PATH` 或 `--no-wmtr`）。
应用捆绑 `libwmtr_host.dylib`；客户机层包含 DXMT 的
`{d3d11,dxgi,d3d10core,winemetal}.dll` 与 `winemetal.so`。若 macOS 无法提供 Metal drawable（例如图层尺寸为零或 drawable 超时），DXMT 会跳过该帧，而不是提交 `nil`（Metal 会因此断言并终止虚拟机，STEAMAC-98）；日志中有限次记录此事，渲染从下一个 drawable 继续。开启时，启动器提供 libkrun 的
wmtr virtio-gpu 上下文（补丁 0018，capset 30），并以 `steamac.gfx=dxmt` 启动虚拟机。
客户机的 `steam-gfx-path` 将每个已安装的 x86-64 Proton 的库替换为 DXMT，并监视 Proton
的安装与更新；关闭后以 `steamac.gfx=vulkan` 启动并恢复 Proton 原始文件。启用可选的 ARM64EC 载荷后，`steam-dxmt-arm64ec` 会从已安装的 **Proton 11.0 (ARM64)** 准备一个单独的兼容工具 **SteamMac DXMT (ARM64EC)**。它使用 DXMT 上游的 ARM64X DLL 与 AArch64 ELF 格式的 `winemetal.so`，让 Wine 与 DXMT 原生运行，FEX 只转换游戏的 x86-64 代码。这个轻量工具包含指向已安装 Proton 的符号链接、约 13 MB 的 DXMT 文件，以及私有前缀模板和需修复的条目，而不是完整的 1.9 GB 副本。原 Proton 文件保持不变，其更新直接通过链接生效。Proton 根据启动它时的路径确定自身目录，并在每次启动时把其 DXVK 组件复制到前缀中：工具中该位置上 DXMT 的 `d3d11`/`dxgi`/`d3d10core` 由此进入前缀；游戏改回 Steam 默认工具后，下次启动又会得到 DXVK。Wine 本身仍是原版；`winemetal` 通过 `WINEDLLPATH` 取自该工具，工具的 `run` 入口在游戏前缀中保留 `winemetal.dll` 条目。Proton 或载荷变化时，工具于 Steam 启动前重建；有游戏正在使用时推迟更新。源 Proton 被删除或不受支持时，托管工具不可用，映射会回退，而不会继续使用失效或不匹配的链接。即使原版 Proton 尚未首次运行，也会在私有前缀模板及需修复的条目中应用 SteamPipe 的空目录和只读权限修复（其他文件仅在需要修复权限时复制）。嵌套的 `tool/` 目录使旧的 x86-64 安装程序不会处理它。

Steam 启动前，`steam-compat-default` **仅为配置中选择 DXMT 的游戏**写入单独的映射：有原生工具时指向它，否则指向 **Proton 10.0**，优先级 250，且仅限启用 DXMT 的启动。旧的仅 x86-64 载荷无法在 ARM64EC Wine 下初始化 winemetal；原生 PE DLL 与原生 Unix 库缺一不可。
适用对象为未被用户指定兼容工具的已安装 Windows
游戏（依据 `libraryfolders.vdf` 与 `appcache/appinfo.vdf`：类型为 game/demo/application，oslist 含 windows
不含 linux）。其余游戏保持 Steam 默认工具 **Proton 11.0 ARM64**，使用 Venus 上的 DXVK/vkd3d-proton。
原先将所有游戏统一映射到 Proton 10.0 的条目会在首次 Steam 启动时移除；之后的配置更改及新安装游戏在下次
Steam 启动时应用，用户在 Steam 中的修改保持不变。这不只是 DLL 的选择：某些游戏在 x86-64 Proton 10.0 + FEX
下无论使用什么 DLL 都会崩溃。例如 Stellar Blade Demo（3564860）的 SEH 递归最终导致
`virtual_setup_exception stack overflow`，但它能在 Proton 11.0 ARM64 上运行。
走回退路径时，Steam 在首次启动 DXMT 游戏时下载 Proton 10.0（x86-64，在 Steam Linux Runtime 3.0 中经 FEX 运行），
`steam-gfx-path --watch` 随后放入 DXMT。**x86-64** 版 Proton Experimental 与 Proton 11.0 需要
x86-64 Steam Linux Runtime 4.0（`SteamLinuxRuntime_4`，应用 4183110）。不要将它们与
**Proton Experimental (ARM64)** 或 **Proton 11.0 (ARM64)** 混淆：后两者使用单独的 ARM64
运行时（`SteamLinuxRuntime_4-arm64`，应用 4185400），Steam 可在 ARM64 上安装。
在游戏的**属性 → 兼容性**中选择名称明确以 **(ARM64)** 结尾的工具；Steam Deck 客户端也提供 ARM64
Experimental，无需为此切换至 Frame 客户端。从不使用通配条目（“0”）：Steam 也会把高优先级
通配应用到自身工具上，曾因此清空 FEX 工具。关闭“允许 DXMT”会删除脚本管理的映射。
Proton 10.0 上的 D3D12 的 Wine 部分改在 FEX 下而非 ARM64EC 运行，会消耗更多 CPU。
已在 M1 Max 上端到端验证：Death's Door（Unity，D3D11）在 Proton 10.0 上启动，渲染器显示
“Apple M1 Max”，并经执行器的图层绘制。同一台 M1 Max 上的测量（macOS 27，虚拟机 6 vCPU / 8 GB，120 Hz，KosmicKrisp）：
Death's Door 标题画面在默认 Proton 11.0 (ARM64) + DXVK 路径约 41 FPS，在 DXMT 上约 117（受 120 Hz 显示器限制）；
d3d11bench 100 次绘制 + 16 次全屏通道为 44 / 50（Proton 10.0 + DXVK）/ 100 FPS，2000 次绘制 + 4 次通道为
133 / 139 / 115（DXMT 止于显示器 120 Hz，Vulkan 路径可超过）。经 Steam 启动的三次 20 秒运行取中位数
（DXMT 取两次启动共六次）；详见网站。
原生 ARM64EC 工具对比 Proton 10.0 + DXMT，M5 Max（macOS 27，虚拟机 12 vCPU / 32 GB，120 Hz，KosmicKrisp，FX Steam Launcher 1.9.13 加 ARM64EC 层；显示帧数来自 `WMTR_FRAMES`，每个工具三次交替运行）。Death's Door 实际游玩（经 uinput 的脚本化键盘输入：行走、翻滚、剑与弓，从同一存档开始 26 秒）两者都保持 120 FPS，没有超过 50 ms 的帧；虚拟机 CPU 占用原生为 330–345%，Proton 10.0 为 406–432%（中位数 342% 对 406%，约少 16%），最差帧 17–32 ms 对 19–49 ms。Super Battle Golf（Unity 6000.3.10f1）在标题画面上两者都保持 120 FPS（CPU 251–279% 对 239–254%：标题画面无法区分两者）。d3d11bench（x86-64，经 Steam 启动，20 秒，中位数）100 次绘制 + 16 次通道为 140 / 138 FPS，2000 次绘制 + 4 个渲染通道为 270 / 267。原生工具启动游戏约快 1.5 秒。Unity 在两个工具上都记录 `ID3D11Fence` 创建不受支持，并继续运行。
DXMT 的 winemetal 调用通过 virtio-gpu 到达 **Mac 上虚拟机进程内部**的执行器，
由其在虚拟机视图内呈现 `CAMetalLayer`。该图层会遮住客户机合成器的光标；启动器改为在其上绘制
游戏自己的光标，尺寸与 gamescope 一致。跟踪由宿主控制，仅用于 DXMT：只有游戏焦点允许显示覆盖层，
且实际 wmtr 图层已附加并可见时才运行，而非仅因开启“允许 DXMT”（见 [DXMT 路径上的光标](architecture.md#dxmt-路径上的光标)）。
D3D12（vkd3d-proton）和原生 Vulkan 仍走 Venus；此路径**仅支持 D3D11/D3D10**，不支持 D3D9。
DXMT 仍有兼容性缺口，包括**不支持流输出（stream output）**；首次启动会编译着色器并可能卡顿，
不能假定 Steam 的 Vulkan 着色器缓存覆盖 Metal。

**安全：开启期间，客户机程序可以以您的用户权限在 Mac 上执行代码。**
进程内执行器与 DXMT 使用宿主原始地址的协议并不是虚拟机安全边界。
因此该路径默认关闭且属实验性；执行器故障也可能使虚拟机停止。仅为您信任的客户机软件启用。

虚拟机启动前，启动器设置 `STEAMAC_WMTR=1`、`STEAMAC_WMTR_LIB`（**执行器库**覆盖项，
否则为应用 Frameworks 或 `work/out/host/lib` 中的 `@rpath/libwmtr_host.dylib`）及
`WMTR_PRESENT=overlay`；关闭时清除三者。库缺失、无法加载或未导出
`wmtr_host_abi_version` 时，本次启动禁用该路径（记入日志并在设置中以红色显示；
显式 `--wmtr-lib` 会带原因退出）；其他 ABI 版本由 libkrun 拒绝。
问题/崩溃报告携带 `wmtr on|off`。

**构建 DXMT。** 在 Apple silicon macOS 上安装 Xcode 的 Metal 工具链
（`xcodebuild -downloadComponent MetalToolchain`）、Rosetta（`softwareupdate --install-rosetta`，
用于 x86-64 Wine 构建工具）、Homebrew，以及为 client 步骤提供 `linux/amd64` 支持的
Docker/OrbStack。脚本安装 `meson ninja cmake pkgconf zstd`。没有 Metal 工具时，
可将 `DXMT_PREBUILT_METAL` 指向包含由相同锁定源码构建的 `dxmt_command.metallib` 和
`air_{msad,samplepos,tessellation}.air` 的目录。

```sh
host/dxmt/build.sh fetch llvm native host pe client payload  # 默认步骤，按顺序执行
host/dxmt/build.sh pe-arm64ec client-arm64 payload-arm64ec    # 增加原生 Proton 11 支持
scripts/build-image.sh layer                               # 纳入客户机载荷
host/launcher/build.sh                                     # 捆绑执行器与更新后的层
```

`fetch` 校验锁定的 DXMT/DirectX 头文件压缩包并应用 `host/dxmt/patches`；
`llvm` 构建静态 LLVM 15.0.7（M2 上约 10 分钟，锁定版本未变时复用）。
`native` 在 `work/build/dxmt-native` 构建 airconv；`host` 构建/测试执行器并安装到
`work/out/host/lib/libwmtr_host.dylib`。`pe` 将四个 DLL 交叉编译到 `work/out/dxmt-pe`；
`client` 在 Docker 内构建/测试 `wmtr/build/x86_64-linux/winemetal.so`；
`payload` 将两者放到 `work/out/dxmt/{x86_64-windows,x86_64-unix}`，
供客户机层的 `/usr/lib/steamac/dxmt/` 使用。各步骤可单独重跑；无参数的
`host/dxmt/build.sh` 会执行默认的 x86-64 步骤。三个可选的 ARM64EC 步骤使用锁定的 Wine 11.2 构建工具与 DXMT 上游的 `build-arm64ec.txt`，在原生 ARM64 容器中构建/测试 Unix 客户端，并把 `work/out/dxmt/{aarch64-windows,aarch64-unix}` 与 x86-64 载荷并列放置。主机执行器由两种架构共用。打包与映射检查：`python3 scripts/test/steam-dxmt-arm64ec.py`、`python3 scripts/test/steam-compat-default.py` 与 `bash scripts/test/steam-gfx-path.sh`。设备创建与缓冲区回读冒烟测试为 `wmtr/tests/d3d11_device_test.c`；在启用 wmtr 执行器的启动中，用原生 DXMT 工具运行其 x86-64 可执行文件。

致谢：[StonkGuy](https://github.com/StonkGuy/steamac) 提供 wmtr 远程调用路径及集成；
[3Shain（Feifan He）的 DXMT](https://github.com/3Shain/dxmt) 提供 Metal 上的 D3D11/D3D10。
`host/dxmt/patches` 中选取的修复保留其作者：David Grinberg、osy、Holly Hamilton、
SteveTanSaMa、hanzpo、Mybono、NerRobDog、时雨与 Jakey-Jakey
（详见打补丁后的 DXMT `STEAMAC-README.md`）。

每个宿主可见客户机分配都是一块 POSIX shm，其文件描述符在虚拟机进程中保持打开（每映射分配约四个），访达启动的进程软限制 256 个描述符：几十个此类分配后游戏丢失 GPU 上下文（STEAMAC-G、Left 4 Dead
2）。虚拟机进程启动时把软限制提到 `kern.maxfilesperproc`（记为“file
descriptors: soft limit 256 → N”）；virglrenderer 记录失败 shm 或描述符操作的 errno（“… failed: Too many open files (RLIMIT_NOFILE 256)”）。

无虚拟机检查：`host/kosmickrisp/build.sh` 对暂存驱动运行 `host/moltenvk/probe` 与复现
（`REPRO_DRIVER=kosmickrisp host/moltenvk/repro/run.sh <dylib>`，经 Khronos loader，仅测试）；`host/virglrenderer/build.sh` 对各已装驱动运行 `venus_check`。
如遇管线创建错误，请参阅[使用 Fossilize 捕获和重放管线](../../host/kosmickrisp/FOSSILIZE.md)。
