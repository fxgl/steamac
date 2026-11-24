# 工作原理

[English](../architecture.md) · [Русский](../ru/architecture.md) · **简体中文**

← [手册](README.md)

## 如何工作

| 目录 | 内容 |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + 补丁：depth_clip_enable、YCbCr 数组、null 描述符、zink/DXVK 用几何着色器模拟（顶点步长、实例化、邻接、扇、SCALED 格式、打包顶点格式：10-10-10-2、RG11B10F、RGB9E5、BGRA8、`gl_in`）、transform feedback（DXVK 流输出）与其查询（SO 统计）、拷贝时查询结果可用（经 Venus 的 DXVK 遮挡查询）、缓冲地址向量分量原子（BDA，vkd3d-proton）、曲面细分下按分量打包的顶点输出（dxil-spirv，Rift Apart）、任意 texel 偏移 texel 缓冲（vkd3d-proton）、robustness2 小推导描述符缓冲写入、可变计数描述符数组做运行时数组（Metal 给 vkd3d-proton 每堆数组留 32 MB 与程序）、辅助缓冲分配、Metal 资源延迟释放、管线缓存 UUID 中补丁哈希、绑定中的 `VK_NULL_HANDLE` 描述符集、片元输出转换为颜色附件的数值类型、没有顶点属性的顶点着色器输入读取零、经浮点格式读取整数顶点输入、辅助函数中 YCbCr 采样器的 null 检查、拒绝不支持的 texel buffer 格式；`repro/` 测试跑在 Metal validation 下（KosmicKrisp 也可：`REPRO_DRIVER=kosmickrisp`）；`bench/run.sh <libdir>…` 比较构建间性能；`bench/shaders.sh <dump or pack>` 从 MoltenVK 着色器转储或 `bench/pack.py` 制作的 10% 采样度量游戏着色器编译（SPIR-V → MSL、MSL → Metal 库、管线状态；冷/热、多线程） |
| `host/kosmickrisp/` | KosmicKrisp（Mesa 主线 @ce576c29）+ 未合并 Mesa MR 与 steamac 补丁（见[Vulkan 驱动](vulkan-drivers.md#vulkan-驱动)），运行时无 LLVM（`-Dllvm=disabled`，`mesa_clc` 来自首构建），`-Db_ndebug=true`；仅 macOS 26+ |
| `host/dxmt/` | 锁定的 DXMT + 补丁、静态 LLVM 15、原生 airconv、Windows DLL 交叉编译与客户机载荷；`build.sh fetch llvm native host pe client payload` |
| `wmtr/` | BSD-3-Clause 的 winemetal 远程调用：客户机 `winemetal.so` 经 virtio-gpu 到达 `libwmtr_host.dylib`（链接 DXMT/LLVM），在虚拟机视图中呈现 CAMetalLayer |
| `host/libepoxy/` | libepoxy 1.5.10，上游 macOS Meson 选项，为 macOS 15.0 而非拷贝 Homebrew 瓶构建 |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + 合并上游主线（venus-protocol 1.1.3）+ LINEAR 修饰符、shm 按宿主内存导入、失败管线桩（virglrenderer 中丢弃绘制）、拒绝缓存重建、延迟 shm 解映射、线程 QoS、运行时打开 Vulkan 驱动（`VKR_VULKAN_DRIVER`） |
| `host/libkrun/` | libkrun v1.19.8（已含 `VIRTIO_GPU_F_BLOB_ALIGNMENT`（16K）与 M4 SME 掩码）+ 补丁：无 virgl 的 2D 资源、`SET_SCANOUT_BLOB`、SHM blob 映射、Venus fence 信令、virglrenderer 日志、`krun_display_resize`（运行时改分辨率）、vCPU/GPU 线程 QoS |
| `host/launcher/` | `steamac-vm`（Swift/AppKit）：Metal 窗口（可选 MetalFX 超分辨率）、带开关机进度的“FX STEAM LAUNCHER”覆盖层、客户机分辨率 = 窗口大小（Retina 分辨率下 × 屏幕 backing scale）恒定 DPI（EDID 取自屏幕物理尺寸）、键盘/鼠标/平板、GameController.framework 的客户机 Xbox 360 / DualSense / DualShock 4 手柄带振动或 DualSense 裸 HID 直通（`fx.pad`）、gvproxy 网络、客户机重启则虚拟机重启、`--perf-stats` |
| `guest/kernel/` | Linux 7.2.9，全编入，4K 页，16K blob 节点对齐，FEX 用 Apple TSO；直通 DualSense 用的 uhid、hidraw 与 `hid-playstation`（含其所需 LED 类） |
| `guest/mesa/` | 来自锁定的 Mesa：Venus ICD aarch64 版（Proton、gamescope、zink）与 x86_64/i386 版（FEX 图形提供方）；两者中替换原装的 zink GL 栈（libgallium、GLX/EGL/GBM），带 `guest/mesa/patches/` 中的回移植（Mesa 6abefa51：仅顶点布局变化时 zink 也重建管线；Metal 上的 Venus 缺 `VK_EXT_vertex_input_dynamic_state`，否则 GL 游戏会用过时的顶点格式绘制）；模拟游戏 x86_64 fault 上报器（`/usr/lib/steamac/x86_64/fault-report.so`） |
| `guest/initramfs/` | 启动阶段 = “bootloader”：带尝试计数的 A/B 槽选择、partsets、`/etc` 与 `/usr` 覆盖；启动器创建磁盘的初始预配（`steamac.provision=1`：initramfs 中静态 mkfs.fat、mke2fs、btrfstune）；`steamac.ssh=0`——无 SSH 服务器；启动器配置载荷（`steamac.config=1`）——新 `steamos` 密码；`steamac.tz=`——`/etc/localtime` 中的 Mac 时区；Flatpak 沙箱用 untouched procfs `/run/steamac/proc`；`steamac.share=`——共享文件夹的运行时挂载单元（virtio-fs `macshare`，见[共享文件夹](clipboard-and-shared-folder.md#共享文件夹)） |
| `guest/layer/` | `/usr` 上虚拟机层（只读 erofs）：文件化 `splctl`、RAUC 安全 post-install、`VARIANT_ID=steamdeck`、DRM 上 gamescope 会话、桌面模式（gamescope 嵌套 Plasma）、Frame 硬件服务屏蔽、`fx-progress-agent` 进度代理（Rust，`guest/progress-agent/`，`fx.progress` virtio-console 端口）与其 root 服务（`fx.clock`、`fx.sleep`、`fx.pad` 上 uinput 或 uhid 手柄）、短关机超时、二维码 Steam 登录模式（无记住账号时用 Steam Deck 客户端）、可选 Steam 客户端分支（`/etc/steamac/steam-client-branch`）、Steam 着色器后台处理默认开启（`steam-shader-defaults`）、Steam 空闲屏保默认关闭（`steam-idle-screensaver`）、重置系统及用户管理器的固定 CPU 亲和性掩码，使服务在使用更新后的层启动时继承虚拟机可用的 vCPU |
| `scripts/` | 构建 `work/out/steamos.img`：Valve 分区布局的 GPT（esp、efi-A/B、rootfs-A/B、var-A/B、home）；`scripts/test/provision-test-disk.sh`——对照 Docker 磁盘的预配开发测试；`scripts/test/vkd3d-tiled.sh`——在临时虚拟机中端到端检查 D3D12 平铺资源与功能级别（Proton 11.0 的 vkd3d-proton 测试、`d3d12-caps`、`vk-minmax`） |

### DXMT 路径上的光标

在 wmtr 路径中，DXMT 在 Mac 的虚拟机进程内以 `CAMetalLayer` 呈现游戏。该图层叠在客户机 scanout
之上，会遮住客户机合成器绘制的光标。每个新客户机代理默认**关闭**跟踪。启动器在 wmtr 图层
可见性/附加状态改变时，经 `fx.progress` 发送 `cursor-track 1|0`，并在 progress 重连或收到客户机
启动握手 `cursor-ready` 时重发当前状态；重复启用会重发完整光标快照。
1 要求游戏焦点允许显示游戏图层，且实际 wmtr `CAMetalLayer` 已附加并可见。Vulkan 及没有此覆盖层的
Steam/桌面不需要光标跟踪；未知宿主命令仍被忽略，以兼容新旧宿主/客户机组合。

启用时，客户机代理（`guest/progress-agent/src/cursor.rs`）寻找活动窗口 `WM_CLASS` 以 `steam_app_`
开头的 Xwayland 显示；必须支持 XFixes 且有活动游戏窗口，不回退到根窗口。
先用 `XFixesGetCursorImage` 获取初始位图，
之后根据 XFixes 光标变更事件更新，不再定期轮询图像；`QueryPointer` 仅在需要时以不超过 60 Hz
采样位置。仅发送变化：`cursor 0|1`、`cursor-image <w> <h> <xhot> <yhot> <base64 BGRA>` 与
`cursor-pos <x> <y> <win_w> <win_h>`。位置及尺寸以焦点游戏 X 窗口客户区像素表示，而非 X 根窗口：
窗口模式游戏的根窗口可能比客户区大。1×1 或全透明光标会隐藏，Wine 用它们表示游戏没有光标。

启动器在 `Progress.swift` 解析消息，经 `Window.swift` 传到 `Presenter.swift` 中的 `VMView`；
它持有名为 `steamac.cursor-overlay`、`zPosition` 为 1000 的透明 `CALayer`。仅当游戏图层可见、
客户机光标可见且位置已知时才显示；不受游戏图层和 Metal HUD 策略影响，wmtr 删除子图层时会重新附加。
位图转换为 premultiplied-first `CGImage`。映射到视图前，位图和热点按 gamescope 的
`--cursor-scale-height 720` 缩放：游戏窗口高度为 H 时，目标尺寸为
`clamp(36 * floor(H / 720), 36, 256)` 像素。与 gamescope 一样，位图任一边超过目标尺寸时会缩小成
目标正方形，热点坐标截断为整数；否则按目标尺寸 / 位图高度等比缩放，倍率不小于 1。
X 窗口位置映射到当前远程游戏图层的实际绘制矩形（将 `drawableSize` 等比适配到图层，与 wmtr
的几何一致），而非客户机画面，因此游戏图层与客户机 scanout 的尺寸或宽高比不同也不会使光标偏移。
合成器负责最终视图缩放及透明度混合。

可见性跟随**游戏自己的光标**，不模拟 gamescope 的 3 秒空闲自动隐藏。Mac 光标策略不变：
auto 模式在画面上隐藏，捕获期间也隐藏；tablet 模式及未捕获的 `--mouse capture` 可能同时显示
Mac 光标和客户机覆盖光标。捕获鼠标用于视角控制本身不会隐藏游戏仍报告为可见的光标。

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

顶点着色器读取管线未提供顶点属性的输入时，Metal 原先会编译失败（“missing from the vertex descriptor”），
管线绘制被跳过（SCS Truck Simulator 的着色器从 location 1 读取 `in_var_NORMAL`，而管线未描述该属性，
STEAMAC-2Y；Vulkan 未定义这些值）。现在这类输入读取零（`repro/vertex_input.c`）。

由浮点顶点格式提供的整数顶点着色器输入（BLUE REFLECTION: Second Light 以 `int4` 从 `Float3`/`Float4`
属性读取 `BLENDINDICES1`，STEAMAC-3N）在 Metal 中编译失败（“cannot be read using MTLAttributeFormatFloat3”），
角色不可见；现在以与格式兼容的类型读取属性并重新解释其位（`repro/vertex_input.c`）。通过带不可变 YCbCr
采样器的辅助函数进行鲁棒采样不再编译失败（`is_null_texture`，STEAMAC-3W；`repro/texture_helpers.c`）。
Metal 没有对应像素格式的 texel buffer view 返回 `VK_ERROR_FORMAT_NOT_SUPPORTED`，而不是使虚拟机进程中止
（Uncharted，STEAMAC-3Q；`repro/texel_buffer.c`）；宽度超过 Metal 2^28 个纹素的 texel buffer view 返回 `VK_ERROR_OUT_OF_DEVICE_MEMORY`，而不是在 Metal 描述符校验中中止（STEAMAC-9E/79）。图形管线失败时记录每个阶段的入口点、着色器哈希与反射接口，
用于没有 MSL 的链接错误和编译器错误。

SteamOS 根文件系统不动：所有改动来自 initramfs 与层。因此
官方 Valve 更新（RAUC + atomupd）装进另一槽并正常回滚——已用 20260922 → 20260928 更新与回滚验证。

层中的 Venus ICD 只链接 SteamOS 更新会保留的 soname（`guest/mesa/container/verify.sh` 的
`check_stable_needed`），不使用 libdisplay-info。SteamOS 0.6.0（preview 频道，20261020）把
`libdisplay-info.so.1` 换成了 `.so.3`：1.9.7 的 ICD 无法加载，gamescope 找不到 Vulkan 设备，虚拟机停在
“Starting Steam client”（STEAMAC-72）。已用 stable → preview 更新到 20261020（0.6.0）验证：更新后的槽位能启动 Steam。
