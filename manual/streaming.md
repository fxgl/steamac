# Streaming and Remote Play

**English** · [Русский](ru/streaming.md) · [简体中文](zh/streaming.md)

← [Manual](README.md)

## LAN networking and Steam Remote Play

Ordinary networking uses gvproxy user-mode NAT (`192.168.127.2` in SteamOS); LAN broadcasts
do not cross that NAT. **Settings → Advanced → LAN Remote Play** (next start), or
`--lan-remote-play`, enables a launcher-side discovery relay and same-port forwards:
UDP **27031–27036**, TCP **27036–27037**, from the Mac to the guest. It is **off by default**:
enabling it exposes Steam's Remote Play services to other machines, independently of SSH.
`--no-lan-remote-play` disables it for one boot; Network off disables it too.

Allow macOS's **Local Network** permission and incoming traffic in the Mac/SteamOS firewall.
Steam Link and the Mac must be on the **same IPv4 subnet** (Wi-Fi client isolation, guest
networks, VLANs, routed discovery and IPv6-only LANs are not supported). Enable Remote Play
in guest Steam; use the Mac's LAN address for manual pairing, not `192.168.127.2`. Steam Link cannot
wake a sleeping SteamOS: wake it from the Mac window, Dock icon or a controller before reconnecting.
Reports with launcher logs include the relay's state and counters, gvproxy's live forwards and log, and
the guest's addresses, routes and listening sockets (STEAMAC-9G).
Quit the Mac's own Steam client if it owns these ports: the launcher never shares or steals
UDP 27036, logs conflicts as `remote-play: disabled for this boot`, and rolls back its forwards.
The Mac Steam client's own UDP 27036 broadcasts are not relayed back into the guest.

The relay preserves Steam client identity and unknown protobuf fields, replaces status
address hints with the Mac's LAN IPv4 address, and retains ports because the forwards use
the same port numbers. Guest status announcements are refreshed by real discovery queries
every five seconds (gvproxy does not export unsolicited guest-subnet broadcasts); no status
is invented when Steam does not answer. Steam may not advertise a signed-out host.
`--selftest-remote-play` checks packet parsing and address rewriting without booting a VM.
For a real LAN probe (on the Mac or a second machine), run
`python3 scripts/test/remote-play-discovery.py --bind <LAN-IP> --broadcast <subnet-broadcast> --expect-host <Mac-LAN-IP>`.
It uses an ephemeral port, prints the actual Steam reply and rewritten address, and fails if
no host answers; it does not claim pairing or streaming success.
Protocol references: [Valve's Remote Play network settings](https://help.steampowered.com/en/faqs/view/3E3D-BE6B-787D-A5D2),
[Steam remote-client protobufs](https://github.com/SteamDatabase/Protobufs/blob/master/steam/steammessages_remoteclient_discovery.proto),
and [discovery envelope framing](https://github.com/OpenSourceLAN/steam-discover/blob/master/listener.js).

## Streaming with Moonlight

**Settings → Streaming → Enable Moonlight streaming** turns on the built-in GameStream host
immediately; it is **off by default** and available only in the windowed VM process. Install
[Moonlight](https://moonlight-stream.org/) on another device on your trusted local network,
allow macOS **Local Network** access and incoming connections, and select this Mac in Moonlight
(or add the Mac's LAN address manually). Enter the four-digit PIN shown on that device in the
pairing window on the Mac, then launch **SteamOS** in Moonlight.

The Streaming tab shows host/session status and paired devices with their pairing dates.
**Revoke** removes a device's access and ends its current stream; it must pair again.
**End stream** disconnects the current session without revoking it. Disabling streaming closes
the listeners and ends the session. VM suspension or SteamOS sleep also stops streaming and
closes the listeners; they return after resume if the setting is still enabled.
While a client streams, the launcher's background-game-pause preference does not freeze the game.

The Mac listens on TCP **47984, 47989** while enabled and TCP **48010** / UDP
**47998–48000** for a session; Bonjour discovery uses **_nvstream._tcp**. Do not expose these
ports to the public Internet. This is independent of **Advanced → LAN Remote Play** and does
not require Steam Link, guest Steam Remote Play, or a virtual display.

The stream contains the guest display, including the visible DXMT game layer, and guest playback
audio—not the Mac desktop, launcher overlays, or microphone. H.264 / supported hardware HEVC
and Opus are used without Screen Recording permission or an audio loopback driver. Moonlight's
requested resolution temporarily owns the guest display (even sizes within the VM's maximum);
ending the stream restores the window's size, or the previous guest resolution if “Guest display
follows the window size” is off. One client streams at a time. Keyboard, mouse,
touch-as-mouse and controllers control the same running guest; local and remote inputs share it.
Moonlight controllers take the first SteamOS player slots ahead of Mac controllers during the
session; with **Additional controllers** off, a Mac controller waits until the stream ends.
The Mac controllers return to their usual slots afterwards.

Moonlight reports PS3, PS4 and PS5 controllers as the same PlayStation type without a reliable
model identifier. SteamOS shows them all as DualSense, with PS5 button glyphs even for PS3 or
PS4 controllers. This changes the reported model, not which controls are supported.

No HDR, native pen/touch, or video encryption is advertised; use a trusted LAN.
`--selftest-stream` runs the component protocol/media checks without booting a VM.
