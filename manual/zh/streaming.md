# 串流与远程畅玩

[English](../streaming.md) · [Русский](../ru/streaming.md) · **简体中文**

← [手册](README.md)

## 局域网与 Steam Remote Play

普通联网走 gvproxy 用户态 NAT（SteamOS 中 `192.168.127.2`）；局域网广播过不了该 NAT。**设置 → 高级 → 局域网 Remote Play**（下次启动生效）或
`--lan-remote-play` 启用启动器侧发现中继与同端口转发：
Mac 到客户机的 UDP **27031–27036**、TCP **27036–27037**。默认**关闭**：
开启会把 Steam 的 Remote Play 服务暴露给其他机器，与 SSH 无关。
`--no-lan-remote-play` 单次启动关闭；网络关闭则一并关闭。

允许 macOS 的**本地网络**权限，并在 Mac/SteamOS 防火墙放行入站。
Steam Link 与 Mac 须在**同一 IPv4 子网**（Wi-Fi 客户端隔离、访客网络、VLAN、路由发现与纯 IPv6 局域网不受支持）。在客户机 Steam 中启用 Remote Play；
手动配对请用 Mac 的局域网地址，而非 `192.168.127.2`。Steam Link 无法唤醒休眠中的 SteamOS：重新连接前请通过 Mac 窗口、Dock 图标或控制器唤醒它。带启动器日志的报告包含中继状态与计数、gvproxy 当前转发与日志，以及客户机的地址、路由和监听端口（STEAMAC-9G）。
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

## Moonlight 串流

**设置 → 串流 → 启用 Moonlight 串流**立即开启内置 GameStream 主机；
默认**关闭**，仅在窗口模式的虚拟机进程中可用。在可信局域网中的另一台设备上安装
[Moonlight](https://moonlight-stream.org/)，允许 macOS 的**本地网络**权限和入站连接，
在 Moonlight 中选择此 Mac（也可手动添加 Mac 的局域网地址）。将设备显示的四位 PIN
输入 Mac 上的配对窗口，然后在 Moonlight 中启动 **SteamOS**。

“串流”标签页显示主机/会话状态、已配对设备和配对日期。**撤销访问权限**会删除设备权限并结束
其当前串流，下次连接须重新配对。**结束串流**断开当前会话但保留配对。关闭串流会停止监听
并结束会话。虚拟机挂起或 SteamOS 睡眠也会停止串流和监听；恢复后，若设置仍开启则恢复监听。
客户端串流期间，启动器的后台暂停游戏设置不会冻结游戏。

启用时 Mac 监听 TCP **47984、47989**；会话使用 TCP **48010** 和 UDP **47998–48000**；
Bonjour 发现使用 **_nvstream._tcp**。不要将这些端口暴露到公网。此功能与
**高级 → 局域网 Remote Play** 独立，不需要 Steam Link、客户机 Steam Remote Play 或虚拟显示器。

串流内容为客户机画面（包括可见的 DXMT 游戏层）和客户机播放音频，不含 Mac 桌面、
启动器叠加层或麦克风。使用 H.264 / 硬件支持的 HEVC 和 Opus，无需屏幕录制权限或音频回环驱动。
Moonlight 请求的分辨率暂时接管客户机显示尺寸（偶数且不超过虚拟机上限），结束后恢复窗口尺寸；
若关闭“客户机显示跟随窗口大小”，则恢复先前的客户机分辨率。
同时仅支持一个串流客户端。键盘、鼠标、触摸转鼠标和控制器与本地输入共同操作同一个运行中的客户机。
会话期间，Moonlight 控制器优先于 Mac 控制器占用 SteamOS 的前几个玩家槽位；
若关闭**其他控制器**，Mac 控制器会等待串流结束。结束后 Mac 控制器恢复原来的玩家槽位。

Moonlight 将 PS3、PS4 和 PS5 控制器报告为同一种 PlayStation 类型，不提供可靠的型号标识。
因此，SteamOS 会将它们都显示为 DualSense；即使是 PS3 或 PS4 控制器，也会显示 PS5 的按键图标。
这只影响显示的型号，不改变支持的操控功能。

不宣告 HDR、原生笔/触摸或视频加密支持，请在可信局域网中使用。
`--selftest-stream` 无需启动虚拟机即可运行协议及媒体组件检查。
