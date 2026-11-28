# 状态与限制

[English](../status.md) · [Русский](../ru/status.md) · **简体中文**

← [手册](README.md)

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
- Heroes of Might and Magic: Olden Era（Unity，DX11）——7 分钟无错误（离线测试）；
- American Truck Simulator（FEX 下的原生 Linux x86_64，经 zink 的 OpenGL 4.6 core）——生涯可加载，
  KosmicKrisp 与 MoltenVK 上世界均正常渲染。

首遍卡顿是 Metal 编译（每新管线约 50–100 ms）；之后约 1 ms。异常关机后重启，initramfs 检查并修复 esp/efi 的 FAT。

## 限制

- DirectX 12（vkd3d-proton）：KosmicKrisp 支持功能级别 12_0（Tiled Resources Tier 2：基于 Metal 4
  placement sparse resources 的稀疏绑定与驻留），MoltenVK 为 11_0；两者均为 SM 6.0（Apple GPU 不支持 SM 6.2+：
  vkd3d-proton 同时要求 FP32 非规格化数的归零与保留，而 Metal 不保留非规格化数）。
  virglrenderer 会记录各设备报告的 SM 6.0 前提条件与 SM 6.2 非规格化数属性。Age of Mythology: Retold
  会因 "Shader model too low (Shader_Model_60)" 停止（STEAMAC-AB/AC/A0）；在使用 KosmicKrisp 的 M5 Max 上，
  启动选项 `VKD3D_DISABLE_EXTENSIONS= VKD3D_SHADER_MODEL=6_6 %command%` 曾绕过此检查进入菜单；
  这只覆盖所报告的着色器模型，对局期间游戏仍可能退出。
  同一渲染通道内，写入稀疏深度附件未绑定图块的深度仍保留在 Apple 的图块内存中。
  Stellar Blade 试玩版（UE4）在 M4 Max 上以 1280×800 达到 60 FPS；首次运行需数分钟编译着色器。
  Proton ARM64 中的 x86 模拟器（FEX）曾在 20 分钟后因其受保护 .exe 的 DEP 检查停止运行。
- 音频：virtio-snd → CoreAudio（默认设备或设置中所选），内置扬声器延迟约 65 ms。启动时，播放按输出设备配置的扬声器布局提供最多 12 个 PCM 声道，
  CoreAudio 明确识别出顶部扬声器时包括它们（如 5.1.2 或 7.1.4）。未分类/离散布局或超过 32 声道的设备使用单声道/立体声；仅有 8 个声道并不意味着 5.1.2，
  也没有 Dolby Atmos 编码。多声道布局时，`audio-layout` 在 WirePlumber 启动前读取 VirtIO ALSA 播放声道映射，用对应的 Pro Audio 输出替换 SteamOS 的立体声策略
  （定时器调度、播放与录音分组：宿主设备时钟彼此独立）；立体声宿主保持 SteamOS 原有配置。默认输出变化或所选设备被拔出时播放立即跟随，布局每秒复查一次，
  按物理扬声器路由并以余量缩混缺少的扬声器。客户机声道映射在一次启动内固定（virtio-snd/ALSA 会缓存）：要让游戏看到更多声道或新布局需重启虚拟机。
  `STEAMAC_SND_DUMP` 记录扬声器映射前的客户机 PCM。5.1.2 已在硬件上测试，7.1.4 仅有自动化映射测试；麦克风仍为单声道/立体声且未经测试。麦克风录音使用 macOS 默认输入。若麦克风权限被拒、没有输入设备或 CoreAudio 在 200 毫秒内未能启动，录音以普通音频错误失败，不会阻塞虚拟机的声音控制队列；播放不受录音影响（STEAMAC-8N/8P：卡住的录音启动曾使客户机的录音缓冲区无法归还）。录音日志包含输入设备和麦克风权限状态。播放输出单元在客户机启动期间创建：CoreAudio 处于冷状态时创建它耗时 2 秒，超过客户机 1 秒的控制超时，导致首个 PCM_PREPARE 超时（STEAMAC-DA）。运行超过 1 秒的声音控制请求会在日志中记录其卡住的 CoreAudio 步骤；较慢但已完成的请求记录其最慢步骤。
- 屏蔽虚拟机的反作弊不可用。
- `logicOp` 不可用（MoltenVK 分支中私有 Metal API 编不过）；zink 报警告。
