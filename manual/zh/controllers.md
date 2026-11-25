# 控制器

[English](../controllers.md) · [Русский](../ru/controllers.md) · **简体中文**

← [手册](README.md)

macOS GameController 框架支持的任何控制器（Xbox、DualSense、DualShock 4、MFi……）
都在 SteamOS 中驱动一个手柄：首个已连接的或在设置 → 控制器中选定的是玩家 1，其余是玩家 2–4（见下文“多个控制器”）。该手柄不是 virtio-input
设备：启动器经 virtio-console 端口 `fx.pad` 发往客户机 root 服务
`fx-pad.service`（`fx-progress-agent pad`，端口出现时由 udev 启动），由它经 uinput 创建。
因此虚拟机运行时它跟随 Mac：控制器连接即出现（Steam 显示“Controller Connected”），其控制器断开即消失，种类随之变化。
设置 → 控制器 → **在 SteamOS 中显示为**（单次启动用 `--pad auto|xbox360|dualsense|dualshock4|steamcontroller`）：

- **自动**（默认）：与驱动它的控制器同类——DualSense（或 Edge）→
  DualSense，DualShock 4 → DualShock 4，其他 → Xbox 360 手柄；Steam Controller 以其本身交给 SteamOS（见下文“Steam Controller 直通”）；
- **Xbox 360 控制器**：内核 `xpad` 驱动呈现的样子（`045e:028e`）；
- **DualSense** / **DualShock 4**：USB 手柄的 `hid-playstation` / `hid-sony` 呈现的样子
  （`054c:0ce6` / `054c:09cc`，版本 `0x8111`，按键按位置，模拟扳机旁另有数字 L2/R2）。Steam 的 SDL 将其映射为 PS5 / PS4 手柄并显示 PlayStation 图标；
- **Steam Controller**：Steam Controller 以其本身交给 SteamOS，其他控制器驱动 Xbox 360 手柄。

**Home / PS 按钮诊断。** 启动器请求 macOS 将此按钮留给 SteamOS，但系统不保证遵从。
如果 USB 正常而蓝牙无效，请比较设置 → 控制器中的 **Home** 实时指示器，在两种连接下
分别按下并松开按钮后提交报告。启动器日志记录 GameController 是否提供 Home、系统手势绑定、
按钮及配置文件回调，以及事件是否进入客户机手柄端口队列；`pad state` 也包含 Home 当前状态。
这些信息用于区分 Mac 输入处理与客户机传递故障，不能将所有蓝牙故障都归因于 DualSense
直通（DualShock 4 使用虚拟手柄）。`pad state` 以及包含启动器日志的问题报告中的 `controllers.txt` 还列出被动的 HID 清单（ID、名称、传输方式、usage 以及每个设备是否被路由及原因；被排除的设备不会被打开，也不请求“输入监控”权限），以及 DualSense 摇杆、原始运动传感器和触摸的最新快照及其时间（STEAMAC-8R/8V）。

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

**通用 HID 操纵杆和手柄。** **自动**模式还会将 GameController 未发布的 Generic Desktop
设备（usage page 1，Joystick 4、Game Pad 5）按其本身直通，
例如 DJI FPV Remote Controller 2（`2ca3:1020`）和 Spektrum SLT6（`35cf:04fb`）。
默认有意不匹配 Multi-axis Controller（8），例如 SpaceMouse。
现有 raw-HID/uhid 路径保留描述符、ID 和报告，由客户机的 `hid-generic`、SDL 和 Steam
处理布局与校准。这不是 Xbox 模拟：请在 SteamOS/Steam Input 中设置，而不是使用启动器的
GameController 实时测试、A/B 互换或死区设置。需要支持 `caps hid` 的新版客户机层。

设备与 GameController、Steam Controller 共享四个玩家位置，取得编号最低且客户机服务支持
HID 的可用空位（玩家 2–4 需启用**更多控制器**）。空闲位置保持不变，但 GameController
控制器优先：通用 HID 会让出位置并移到下一个空位，没有空位则等待。蓝牙 LE Steam Controller
仍保留固定位置，不会被挤走。旧客户机没有 `caps hid` 时，通用 HID 不预留位置，
也不能唤醒暂停的虚拟机。
关闭**虚拟控制器**（`--no-gamepad`），或在**在 SteamOS 中显示为**选择明确的类型，
即可停止通用 HID 的发现与直通。`pad state` 会列出名称、VID/PID、registry ID 和玩家位置。

为避免重复输入，只有 `GCController.supportsHIDDevice` 为 true（按 HID registry ID 缓存），
**且** `GCController.controllers()` 中确实存在已发布的控制器，其 `vendorName` 或
`productCategory` 与 HID 的 product、manufacturer 或“manufacturer product”完全匹配时，
才认为通用 HID 归 GameController 管理。匹配忽略大小写，并将连续空白归一为空格。
公开 API 无法关联控制器与 HID，因此使用名称匹配，而非猜测 VID/PID。
声明支持的设备在发现后等待 **2 秒**供异步发布，期间不打开设备；
若仍无匹配的控制器，则按通用 HID 直通，包括 macOS 声称支持的 DJI C5。
之后若出现匹配的 GC 控制器，会在分配玩家前释放通用 HID 路径；GC 断开时重新提供 HID。
每次等待、接受或因 GC 跳过/释放的状态转换只记录一行日志，包含 VID:PID 和产品名称。
DualSense 和 Valve 设备仍走原有路径。发现使用独立设备模式的 IOHIDManager：
匹配本身不会打开无关设备或请求“输入监控”。普通操纵杆/手柄集合不需要此权限；
带键盘/鼠标/触控板集合的已连接复合控制器可能需要，只有打开已选中的控制器时才可能请求。
Apple 在 [IOHIDDevice](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.cpp)
中标记这些集合，[设备插件](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDLib/IOHIDDeviceClass.m)
在打开时请求访问权限，而不是在匹配 usage 时请求。

**Steam Controller 直通。** **在 SteamOS 中显示为**为“自动”或“Steam Controller”时，Steam Controller（2026）经同一 uhid 路径以其本身交给 SteamOS，Steam 用自己的驱动处理其触控板、陀螺仪、背键和振动。单独连接时为玩家 1；开启**更多控制器**时，若旁边还有其他控制器（例如玩家 1 的 DualSense），Steam Controller 会成为下一个空闲玩家，而不是被丢弃：
- 通过蓝牙 LE 连接到 Mac（`28de:1303`）：以其自身 ID 和蓝牙总线直通。GameController 不显示它，因此不需要 GameController 控制器，也无法唤醒休眠中的客户机（虚拟机暂停时会丢弃 HID 输入）；
- 通过 USB 线接到 Mac（`28de:1302`）：以其自身 ID 和 USB 总线直通，与蓝牙相同，需要输入监控。当唯一的 USB 控制器能与其 GameController 替身明确对应时，HID 保留该玩家的位置，不额外创建 Xbox 360 手柄；蓝牙直通不会禁用其他 GameController 手柄；
- 通过其 Puck 接收器（`28de:1304`）：Puck 的接口 2–5 是控制器槽位，带有控制器本身的报告描述符。SDL 与 Steam 只按 USB 接口号识别 Puck 的控制器，而 uhid 设备没有接口号，因此传输控制器状态的槽位以有线 Steam Controller（`28de:1302`，USB 总线）交给 SteamOS；槽位超过 2 秒没有控制器状态即移除（控制器关闭、换到其他槽位或蓝牙），由 Puck 的 GameController 手柄接替。在**桌面模式**下宽限为 30 秒，除无线状态外的所有输入报告都会保持槽位存活，包括 lizard 模式的键盘/鼠标报告和电池报告。这使桌面使用期间的 Valve 直通保持稳定，包括用 Options 唤醒控制器后。无线状态不会延长任一超时，Disconnect 状态会在两种模式下立即移除槽位。切换到桌面模式不会重新激活已超过游戏模式 2 秒超时的槽位。只有恰好一名玩家的 GameController 控制器是 Steam Controller、且恰好一个 Puck 槽位活跃时，才将它直通给该玩家；否则这些玩家继续使用 uinput 手柄，因为无法可靠地将槽位与控制器对应。

其报告描述符含键盘和鼠标集合（控制器的桌面模式），因此 macOS 只有在系统设置 → 隐私与安全性 → **输入监控**允许后才打开它：启动器会请求该权限，授予后立即打开设备（`hid passthrough: Input Monitoring granted, reopening the HID manager`）。macOS 把蓝牙 LE Steam Controller 64 字节的 feature report 1（Steam 的命令通道）返回为 65 字节，因此只有该控制器经蓝牙的 GET_REPORT 缓冲区在描述符尺寸之外留有余量；USB DualSense 使用描述符的原始尺寸（1.9.9 中带余量时其固件 report 32 超时，STEAMAC-84）。断开的控制器按启动器持有的设备引用移除，因此经 USB 或蓝牙重新连接后直通的是新设备。
控制器需要此权限时，设置 → 控制器会显示警告，并提供 **Mac 输入监控设置…** 按钮，请求访问权限并打开相应的系统设置页面。警告仅在启用 Steam Controller 或通用 HID 控制器匹配时显示。如果已启用访问权限但控制器仍不可用，请重新启动启动器。

**多个控制器。** 开启设置 → 控制器 → **更多控制器**（默认开，立即生效）后，其余已连接的控制器成为玩家 2–4，在 SteamOS 中各有自己的手柄，用于本地合作。每个玩家一个 virtio-console 端口：玩家 1 用上述 `fx.pad`，其余用 `fx.pad2` … `fx.pad4`，各由以端口命名的 `fx-pad@.service` 实例服务（同一个 `fx-progress-agent pad`，以 `FX_PAD_PORT` 指定端口，由 udev 启动），因此各玩家端口上的协议相同，手柄的振动在驱动它的控制器上播放。客户机对应端口的服务发出 `hello` 后该玩家才获得控制器：没有 `fx-pad@.service` 的客户机层仍只有一个手柄。设置中选定的控制器是玩家 1，除非该位置已被蓝牙 LE Steam Controller 占用；玩家的控制器在断开前保持不变（其他玩家不递补），重新连接的控制器占用第一个空位。蓝牙 LE Steam Controller 也保持其玩家位置：较低编号玩家断开不会使其递补，新连接的 GameController 控制器也不会将其挤走。BLE 控制器断开时释放位置，重新连接时占用编号最低的可用空位。**在 SteamOS 中显示为**、A/B 互换与死区对所有手柄生效（“自动”时每个手柄与各自的控制器同类）。只有玩家 1 的 DualSense 可直通，且另一玩家的控制器也是 DualSense 时不直通（GameController 不报告哪个 HID 设备属于谁）：此时两者都获得 uinput 手柄。Steam Controller 可直通给任意空闲可用玩家（见上文）。虚拟机运行时，设置 → 控制器中的实时输入测试会标出每个控制器对应的玩家（**玩家 2**）。关闭：只使用玩家 1；BLE Steam Controller 不会挤走已占用该位置的 GameController 控制器，如果 BLE 已占据该位置，新连接的 GameController 控制器则需等待。

`--control-fifo` 测试命令：`pad on`（无控制器的手柄，如 `--input-selftest` 所用）、
`pad off`、`pad test`（A + 左摇杆）——均可带玩家编号（`pad on 2`；不带则为 1）——以及 `pad state`（客户机手柄、上次振动等级、客户机是否接管 HID 设备、已连接 DualSense 与 Steam Controller 及直通输入报告数）。
