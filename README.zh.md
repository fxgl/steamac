<p align="center"><img src="docs/media/icon.png" width="96" height="96" alt=""></p>

<h1 align="center">FX Steam Launcher</h1>

<p align="center">
Valve 官方 ARM64 SteamOS（Steam Frame 构建）在 Apple Silicon 轻量虚拟机中运行。<br>
Windows 游戏 GPU 加速、任意手柄、原生声音。
</p>

<p align="center">
<a href="https://github.com/fxgl/steamac/releases/latest"><b>下载</b></a> ·
<a href="https://fxgl.github.io/steamac/">网站</a> ·
<a href="https://fxgl.github.io/steamac/games.html">游戏统计</a> ·
<a href="manual/zh/README.md">手册</a>
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.ru.md">Русский</a> · <b>简体中文</b></p>

![在 FX Steam Launcher 中运行的 Steam 大屏幕界面](docs/media/shot-library.jpg)

## 安装

1. 从 [Releases](https://github.com/fxgl/steamac/releases/latest) 下载 DMG，打开后把 FX Steam Launcher
   拖到“应用程序”。应用经 Apple 签名与公证。
2. 启动并选择 **新建磁盘…**：选择 SteamOS 分支、游戏分区大小与 Steam 客户端，接受 Valve 的 SteamOS
   许可和 Steam 订户协议。启动器下载 Valve 签名映像（约 4.5 GB），校验后写入磁盘。
3. 登录 Steam 并安装游戏——Proton 11（ARM64）与 FEX 由 Steam 自行带来。

需要 Apple 芯片 Mac、macOS 15 或更高版本，创建磁盘需约 20 GB 空闲空间。磁盘为稀疏文件，随安装游戏增长。
更新可在应用内直接安装。

## 支持的功能

- **DirectX 9/10/11** 通过 DXVK，**DirectX 12** 通过 vkd3d-proton，OpenGL 通过 zink。
- **x86-64 Windows 与 Linux 游戏**通过 ARM64 版 Proton 11 和 FEX 运行，使用 Apple 硬件 TSO。
- **控制器**：Xbox、DualSense（也可直通，支持触摸板、陀螺仪和自适应扳机）、DualShock 4、MFi 与
  Steam Controller，均支持震动。游戏中可捕获鼠标用于视角控制。
- **声音**通过 CoreAudio，最多 12 声道（5.1、7.1、7.1.4），并支持麦克风。
- 挂起到内存、**桌面模式**、共享**剪贴板**与**文件夹**、**Moonlight** 串流以及局域网内的
  **Steam 远程畅玩**。
- 两个 Vulkan 驱动：**KosmicKrisp**（Metal 4，macOS 26+ 上的默认驱动）和 **MoltenVK**（Metal 3）。

哪些游戏能运行、表现如何，见玩家汇报的[游戏统计](https://fxgl.github.io/steamac/games.html)。

## 局限

- 需要 DirectX 12 功能级别 12_1 或 shader model 6.6（Unreal Engine 5）的游戏无法启动。
- 屏蔽虚拟机的反作弊不会放行。
- 新特效在 Metal 编译时会卡顿一次（约 50–100 毫秒），之后走缓存。

详见[状态与限制](manual/zh/status.md)。

## 工作原理

```
game (DX9/10/11) ─ DXVK (Proton 11, x86 via FEX) ─ Vulkan
   └─ guest Mesa Venus ─ virtio-gpu (blob, 16K alignment)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

libkrun 在 Hypervisor.framework 上启动 Valve 签名的 SteamOS 映像，不使用 QEMU。SteamOS 根文件系统从不修改，
因此官方 A/B 更新与 Steam Deck 上一样可用。所有组件与补丁集见[工作原理](manual/zh/architecture.md)。

## 从源码构建

```sh
git clone https://github.com/fxgl/steamac
cd steamac
./build.sh    # MoltenVK、KosmicKrisp、virglrenderer、libkrun、启动器、客户机内核、Mesa、磁盘
./run.sh      # 在窗口中运行 SteamOS
```

需要 Xcode 26+、Homebrew、rustup 与 OrbStack（或支持 arm64 与特权容器的 Docker）。
完整指南见[从源码构建](manual/zh/building.md)。

## 手册

| 主题 | 内容 |
|---|---|
| [使用启动器](manual/zh/using.md) | 应用本身、卸载、语言、Steam 客户端、登录 |
| [设置](manual/zh/settings.md) | 设置窗口的每个标签页与按游戏配置 |
| [控制器](manual/zh/controllers.md) | 手柄、DualSense 直通、Steam Controller、鼠标与键盘 |
| [Vulkan 驱动](manual/zh/vulkan-drivers.md) | MoltenVK 与 KosmicKrisp：各自支持什么、如何切换 |
| [串流与远程畅玩](manual/zh/streaming.md) | 局域网、Steam 远程畅玩与 Moonlight |
| [挂起与睡眠](manual/zh/suspend-and-sleep.md) | 把 SteamOS 挂起在内存中，以及 SteamOS 自身的睡眠 |
| [桌面模式](manual/zh/desktop-mode.md) | 虚拟机中的 Plasma 桌面 |
| [剪贴板与共享文件夹](manual/zh/clipboard-and-shared-folder.md) | 与 SteamOS 共享文本、图片和 Mac 文件夹 |
| [崩溃报告、更新与游戏统计](manual/zh/privacy-and-updates.md) | 发送什么、何时发送、如何关闭 |
| [报告问题](manual/zh/report-a-problem.md) | 问题报告包含什么、如何发送 |

## 参与贡献

欢迎提交错误报告、游戏报告、翻译与补丁。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。

## 许可证

项目代码采用 Apache License 2.0（`LICENSE`），© 2026 FX GAMES FZ LLC。例外见
`NOTICE`：Linux 内核补丁与配置——仅 GPL-2.0，virglrenderer 与 Mesa
补丁——MIT（如这些项目），五个源自 Valve
`deckard-steamvr-session` 包的 gamescope 会话文件——MIT © Valve Corporation；Valve CA 证书与
`docs/media` 截图不在项目许可范围内。许可文本在 `LICENSES/`。

SteamOS 非项目组成部分，也不随项目分发：应用在用户接受 Valve 许可后从 Valve 服务器下载签名映像
（见“无需 Docker 创建 SteamOS 磁盘”）。

Steam、Steam 标志、SteamOS、Steam Deck 与 Steam Frame 是 Valve Corporation 在美国和/或其他国家的商标和/或注册商标。本项目与 Valve Corporation 无关，也未经其背书。
