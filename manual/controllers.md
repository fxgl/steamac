# Controllers

**English** · [Русский](ru/controllers.md) · [简体中文](zh/controllers.md)

← [Manual](README.md)

Any controller macOS's GameController framework supports (Xbox, DualSense, DualShock 4, MFi, …)
drives a gamepad in SteamOS: the first connected one, or the one picked in Settings → Controller,
is player 1, and further ones are players 2–4 (“Several controllers” below). The pad is not a virtio-input
device: the launcher sends it over the virtio-console port `fx.pad` to the guest's root service
`fx-pad.service` (`fx-progress-agent pad`, started by udev when the port appears), which creates it
with uinput. So it follows the Mac while the VM runs: it appears when a controller connects (Steam
shows “Controller Connected”), disappears when its controller goes, and changes kind with it.
Settings → Controller → **Appears in SteamOS as** (`--pad auto|xbox360|dualsense|dualshock4|steamcontroller`
for one run):

- **Automatic** (default): the same kind as the controller that drives it — DualSense (or Edge) →
  DualSense, DualShock 4 → DualShock 4, anything else → Xbox 360 controller; a Steam Controller
  goes to SteamOS as itself (“Steam Controller passthrough” below);
- **Xbox 360 controller**: what the kernel's `xpad` driver exposes (`045e:028e`);
- **DualSense** / **DualShock 4**: what `hid-playstation` / `hid-sony` expose for a USB pad
  (`054c:0ce6` / `054c:09cc`, version `0x8111`, face buttons by position, digital L2/R2 besides the
  analog triggers). Steam's SDL maps it as a PS5 / PS4 controller and shows PlayStation glyphs;
- **Steam Controller**: a Steam Controller goes to SteamOS as itself, any other controller drives an
  Xbox 360 controller.

**Home / PS button diagnostics.** The launcher requests that macOS leave this button to SteamOS,
but macOS can override that preference. If it works over USB but not Bluetooth, compare
Settings → Controller's live **Home** indicator and send a report after pressing and releasing
the button on each connection. The launcher log records whether GameController exposes Home,
its system-gesture binding, button and profile callbacks, and whether the Home event was queued
for the guest pad port; `pad state` includes the current Home state. This distinguishes host input
handling from guest delivery without assuming that a Bluetooth failure is a DualSense passthrough
problem (DualShock 4 uses the virtual pad). `pad state`, and `controllers.txt` in a problem report that
includes launcher logs, also list a passive HID inventory (IDs, names, transport, usages and why each
device is or isn't routed; excluded devices are never opened and Input Monitoring is not requested) and
the latest DualSense stick, raw motion-sensor and touch snapshot with its age (STEAMAC-8R/8V).

**Rumble.** The pad has `FF_RUMBLE`, like the real drivers, so SDL and Steam rumble it — games
through Steam Input reach it via Steam's virtual Xbox pad. uinput leaves playback to its user-space
driver: `fx-pad` implements the kernel's ff-memless rules (delay, length, repetitions, re-upload,
effects adding up) and sends the combined level, `rumble <strong> <weak>`, to the launcher, which
plays it with GameController haptics: the strong motor on the left handle, the weak one on the
right (one level everywhere on controllers without separate handles); nothing while the VM is
paused. Port protocol: `guest/progress-agent/src/pad.rs`. Touchpad, gyro, lightbar and adaptive
triggers are HID features of the real controller that this evdev device does not carry.

**DualSense passthrough.** When a DualSense (or Edge) drives the pad and it appears as a
DualSense, Settings → Controller → **Pass a DualSense through** (on by default, applies now) gives
SteamOS the controller itself instead of the uinput pad. The launcher opens it as a raw HID device
(IOHIDManager, without seizing it: GameController still selects it and wakes a sleeping guest) and
`fx-pad` recreates it with `/dev/uhid`: same report descriptor, vendor/product, and USB or Bluetooth
bus. The guest's `hid-playstation` driver binds to it as to a plugged-in controller (gamepad,
touchpad, motion sensors, lightbar and player LEDs, mute LED) and Steam uses its own HIDAPI
DualSense driver on `/dev/hidraw*`, so Steam Input gets touchpad, gyro and the mute button, and
drives rumble, lightbar and adaptive triggers itself. Input reports go to the guest as they are
(`hid-input`); output reports, GET_REPORT and SET_REPORT go back to the controller (`hid-output`,
`hid-get` / `hid-get-reply`, `hid-set` / `hid-set-reply`, hex with the report ID first). While the
guest falls behind, older input reports are dropped instead of queued: each carries the whole
state. Swap A/B and the stick dead zone do not apply to a passed-through controller. GameController
does not say which HID device a controller is: with several DualSenses connected, the first one
found is passed through. Older guest layers without `caps hid` keep getting the uinput pad.

**Generic HID joysticks and gamepads.** **Automatic** also passes Generic Desktop (usage page 1)
Joystick (4) and Game Pad (5) devices not published by GameController
through as themselves: for example DJI FPV Remote Controller 2 (`2ca3:1020`) and Spektrum SLT6
(`35cf:04fb`). The existing raw-HID/uhid path preserves the descriptor, IDs and reports; the
guest's `hid-generic`, SDL and Steam handle layout and calibration. This is not Xbox emulation:
configure the device in SteamOS/Steam Input, not the launcher's live GameController input test,
A/B swap or deadzone. A current guest layer with `caps hid` is required.
Multi-axis Controller (8), such as SpaceMouse, is deliberately not matched by default.

Each device takes the lowest free usable player whose guest service supports HID, sharing the
four players with GameController and Steam Controllers (enable **Additional controllers** for
players 2–4). It keeps its player while free, but yields to a GameController controller and moves
to the next free player, or waits if none is available. BLE Steam Controller reservations remain
sticky and are not displaced. Generic devices cannot reserve a player on an older guest without
`caps hid`, and cannot wake a paused VM. Turn off **Virtual controller** (`--no-gamepad`) or
choose an explicit **Appears in SteamOS as** kind to stop generic discovery and passthrough.
`pad state` lists each generic controller's name, VID/PID, registry ID and reserved player.

To avoid duplicate input, a generic HID is GameController-owned only when
`GCController.supportsHIDDevice` is true (cached per HID registry ID) **and** a published
`GCController.controllers()` entry has a `vendorName` or `productCategory` exactly matching
the HID product, manufacturer, or “manufacturer product”, ignoring case and collapsing whitespace.
There is no public controller-to-HID link; this is a name match, not a VID/PID guess.
Supported devices wait unopened for **2 seconds** after discovery for asynchronous publication;
without a matching controller they then pass through as generic HID, including the DJI C5
even when macOS advertises support. A later matching GC connection releases the generic route
before player assignment; disconnecting it re-offers the HID device. Each hold, acceptance or
GC-owned skip/release is logged once per transition with VID:PID and product.
DualSense and Valve devices keep their existing routes.
Discovery uses an independent-devices IOHIDManager: matching does
not open unrelated devices or request Input Monitoring. Ordinary joystick/gamepad collections
do not need that permission; a connected composite controller with keyboard/mouse/trackpad collections
may need it, and only opening an accepted controller can request it. Apple marks those collections
in [IOHIDDevice](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDDevice.cpp);
its [device plugin](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDLib/IOHIDDeviceClass.m)
requests access on open, not on usage matching.

**Steam Controller passthrough.** With **Appears in SteamOS as** Automatic or Steam Controller, a
Steam Controller (2026) goes to SteamOS as itself through the same uhid path, so Steam drives its
trackpads, gyro, back buttons and haptics with its own driver. Alone it is player 1; with
**Additional controllers** on, a Steam Controller next to another controller (for example a
DualSense on player 1) becomes the next free player instead of being dropped:
- connected to the Mac over Bluetooth LE (`28de:1303`): passed through with its own IDs and the
  Bluetooth bus. GameController does not show it, so it does not need a GameController controller,
  and it cannot wake a sleeping guest (HID input is dropped while the VM is paused);
- plugged into the Mac over USB (`28de:1302`): passed through with its own IDs and the USB bus,
  with the same Input Monitoring requirement as Bluetooth. When one USB controller can be matched
  unambiguously to its GameController stand-in, HID keeps that player's slot without an extra Xbox
  360 pad; BLE passthrough does not suppress other GameController pads;
- through its Puck (`28de:1304`): interfaces 2–5 of the Puck are its controller slots, with the
  controller's own report descriptor. SDL and Steam take the Puck's controllers only by USB interface
  number, which a uhid device does not have, so the slot that carries controller state goes to
  SteamOS as a wired Steam Controller (`28de:1302`, USB bus); a slot without controller state for
  2 s is removed again (controller off, moved to another slot or to Bluetooth), and the
  GameController pad of the Puck takes over. In **Desktop Mode** the grace is 30 s and all input
  reports except wireless status keep the slot alive, including lizard-mode keyboard/mouse and
  battery reports. This keeps Valve passthrough stable during desktop use, including after
  Options wakes the controller. Wireless status never extends either timeout, and a Disconnect
  status removes the slot immediately in both modes. Switching to Desktop Mode does not revive
  a slot already expired under the 2 s Gaming Mode timeout. That player's Steam Controller is
  passed through only when exactly one player's GameController controller is a Steam Controller
  and exactly one Puck slot is live; otherwise those players keep uinput pads, since the slots
  cannot be matched to their controllers reliably.

Its report descriptor has keyboard and mouse collections (the controller's desktop mode), so macOS
opens it only with System Settings → Privacy & Security → **Input Monitoring**: the launcher asks
for it and opens the device as soon as it is granted (`hid passthrough: Input Monitoring granted, reopening the HID manager`).
Settings → Controller shows a warning when a controller needs this permission, with an
**Mac Input Monitoring Settings…** button that requests access and opens the relevant System Settings pane.
The warning is shown only while Steam Controller or generic HID matching is enabled. If access is already
enabled but the controller is still unavailable, restart the launcher.
macOS returns a Bluetooth LE Steam Controller's 64-byte feature report 1 (Steam's command channel) as
65 bytes, so only that controller's Bluetooth GET_REPORT buffers have headroom over the descriptor's
sizes; a USB DualSense gets exactly the descriptor's sizes (its firmware report 32 timed out with the
headroom in 1.9.9, STEAMAC-84). A disconnected controller is removed by the device reference the launcher
holds, so reconnecting it over USB or Bluetooth passes through the new device.

**Several controllers.** With Settings → Controller → **Additional controllers** (on by default,
applies now) further connected controllers are players 2–4, each with a gamepad of its own in
SteamOS, for local co-op. Every player has a virtio-console port: `fx.pad` for player 1, as above,
and `fx.pad2` … `fx.pad4`, each served by an instance of `fx-pad@.service` named after its port
(the same `fx-progress-agent pad` with `FX_PAD_PORT`, started by udev), so the protocol on a port
is the same for every player, and a pad's rumble plays on the controller that drives it. A player
gets a controller once the guest's service of that port said `hello`: a guest layer without
`fx-pad@.service` keeps the one pad. The controller chosen in Settings is player 1 unless a
Bluetooth LE Steam Controller already occupies that player. A player keeps their controller until
it disconnects (the others do not move up), and a reconnected controller takes the first free player.
A Bluetooth LE Steam Controller also keeps its player: a lower player's disconnect does not move
it up, and a newly connected GameController controller cannot displace it. Disconnecting the BLE
controller frees its player; reconnecting it takes the lowest free usable player.
**Appears in SteamOS as**, swap A/B and dead zone apply to every pad (with
Automatic each pad is the kind of its own controller). Only player 1's
DualSense is passed through, and not while another player's controller is a DualSense too
(GameController does not say which HID device is whose): both get uinput pads then. A Steam
Controller is passed through on any free usable player (see above). While the VM
runs, the live input test in Settings → Controller badges each controller with its player
(**Player 2**). Off: only player 1 is used; a BLE Steam Controller does not displace an existing
GameController controller, and a new GameController controller waits if BLE already owns that player.

`--control-fifo` test commands: `pad on` (a pad without a controller, as `--input-selftest` uses),
`pad off`, `pad test` (A + left stick) — each takes a player number (`pad on 2`; 1 if not given) —
and `pad state` (the guest's pads, their last rumble level, whether the guest takes HID devices,
connected DualSenses and Steam Controllers, and input reports passed through).
