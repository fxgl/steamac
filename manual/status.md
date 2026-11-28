# Status and limitations

**English** · [Русский](ru/status.md) · [简体中文](zh/status.md)

← [Manual](README.md)

## Status

Verified:

- SteamOS boots to `graphical.target`, autologin, gamescope session; networking (DHCP via gvproxy,
  downloading a 583 MB Steam client update), SSH;
- Venus in the guest: `Virtio-GPU Venus (Apple M4 Max)`, Vulkan 1.4; render test (compute + clear/copy)
  and display output through KMS match the reference pixel for pixel;
- all required DXVK features from Proton 11 / DXVK 3.x are visible in the guest (geometryShader,
  shaderCullDistance, depthClipEnable, robustness2 + nullDescriptor, maintenance5/6, …);
- keyboard, tablet, mouse, and the virtual pad are visible in SteamOS; as a DualSense, Steam's SDL
  maps it as `PS5 Controller` (type PS5) and shows PlayStation glyphs; the pad appears, disappears
  and changes kind while the VM runs; rumble from SDL and from Steam's virtual pad reaches the
  launcher (`rumble 49152 16384` for 1.5 s, then 0); playing it on a physical controller is not
  verified yet;
- DualSense passthrough, guest side: a uhid DualSense with the real USB report descriptor, fed by a
  stand-in for the launcher, binds `hid-playstation` (gamepad, touchpad, motion sensors, headset
  jack, RGB and player LEDs); touch position and touchpad click reach the touchpad device, the mute
  button toggles the mute LED through an output report back to the Mac side, and Steam opens
  `/dev/hidraw*` with its HIDAPI driver (`Controller using HIDAPI driver, vid=0x054c, pid=0x0ce6`).
  The Mac side (IOHIDManager, a physical DualSense over USB or Bluetooth) is not verified yet;
- Desktop Mode: Switch to Desktop, the Plasma desktop with mouse input (also letterboxed), Return to
  Gaming Mode, booting straight into the desktop; Flatpak sandboxes start;
- A→B update via official OTA and rollback;
- GL via zink (glamor in Xwayland, glxgears ~60 FPS), Steam UI (gamepad UI, CEF with GPU)
  renders in the VM window;
- Steam sign-in, installation of Proton 11.0-2 (ARM64) and FEX, running a DX11 game (Death's Door)
  through DXVK → Venus → MoltenVK;
- guest resolution follows the window size at constant DPI; fast shutdown (2–4 s);
- Heroes of Might and Magic: Olden Era (Unity, DX11) — 7 minutes without errors (offline test);
- American Truck Simulator (native Linux x86_64 under FEX, OpenGL 4.6 core through zink) — a career loads
  and the world renders on KosmicKrisp and on MoltenVK.

Stutters on the first pass are Metal compilation (~50–100 ms per new pipeline); subsequent passes take
~1 ms. On reboot after an abrupt shutdown, initramfs checks and repairs FAT on esp/efi.

## Limitations

- DirectX 12 (vkd3d-proton): feature level 12_0 on KosmicKrisp (tiled resources tier 2: sparse binding and
  residency on Metal 4 placement sparse resources), 11_0 on MoltenVK; SM 6.0 on both (no SM 6.2+ on Apple GPUs:
  vkd3d-proton needs both FP32 denormal flush-to-zero and preservation, and Metal does not preserve denormals).
  virglrenderer logs the SM 6.0 prerequisites and SM 6.2 denormal properties each device reports. Age of
  Mythology: Retold stops with "Shader model too low (Shader_Model_60)" (STEAMAC-AB/AC/A0); on an M5 Max with
  KosmicKrisp the launch options `VKD3D_DISABLE_EXTENSIONS= VKD3D_SHADER_MODEL=6_6 %command%` got past this
  check to the menu; this only overrides the reported shader model, and matches may still exit.
  Within one render pass, depth written to unbound tiles of a sparse depth attachment stays in Apple's tile memory.
  Stellar Blade Demo (UE4) runs at 1280×800, 60 FPS on an M4 Max; the first run spends minutes compiling shaders. The
  x86 emulator in Proton ARM64 (FEX) stopped it once after 20 minutes (DEP check in its protected .exe).
- Audio: virtio-snd → CoreAudio (default device or one selected in settings), latency ≈65 ms on built-in
  speakers. At boot, playback exposes up to 12 PCM channels from the output device's configured speaker
  layout, including height speakers (e.g. 5.1.2 or 7.1.4) when CoreAudio identifies them explicitly. An
  unclassified/discrete layout, or a device with more than 32 channels, gets mono/stereo; 8 channels alone
  do not imply 5.1.2, and there is no Dolby Atmos encoding. For a multichannel layout, `audio-layout`
  reads the VirtIO ALSA playback map before WirePlumber starts and replaces SteamOS's stereo policy with
  the matching Pro Audio output (timer scheduling, separate playback/capture groups: the host devices
  have independent clocks); a stereo host keeps the stock SteamOS profile. Playback follows a new
  default or unplugged output at once and rechecks the layout once a second, routing to the physical
  speakers and downmixing missing ones with headroom. Guest channel maps stay fixed for a boot
  (virtio-snd/ALSA cache them): restart the VM to expose more channels or a new layout to games.
  `STEAMAC_SND_DUMP` records guest PCM before speaker mapping. 5.1.2 was tested on hardware, 7.1.4
  only by automated mapping tests; the microphone stays mono/stereo and has not been tested. Microphone
  capture uses the macOS default input. If microphone permission is denied, no input device is
  available or CoreAudio does not start within 200 ms, recording fails with an ordinary audio error
  instead of blocking the VM's sound control queue; playback is independent of capture (STEAMAC-8N/8P:
  a stuck capture start left the guest's capture buffers outstanding). Capture logs include the input
  device and microphone permission state. The playback output unit is created while the guest boots:
  on a cold CoreAudio creating it took 2 s, past the guest's 1 s control timeout, so the first
  PCM_PREPARE timed out (STEAMAC-DA). A sound control request still running after 1 s is logged with
  the CoreAudio step it is blocked in; a slow one that finishes logs its slowest step.
- Anti-cheat systems that block VMs will not work.
- `logicOp` is unavailable (the private Metal API in the MoltenVK fork does not build); zink emits a warning.
