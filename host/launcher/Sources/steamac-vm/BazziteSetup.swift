import Darwin
import Foundation

/// Per-disk first-boot configuration appended to Fedora's initramfs. Passwords
/// are hashed on the Mac; no plaintext is written to the guest or the sidecar.
enum BazziteSetup {
    /// Upgrade existing guests without touching their disk or account data.
    static func installSteamCompatibility(initrd: URL) throws {
        let receipt = initrd.deletingLastPathComponent().appendingPathComponent("steam-compat-v9")
        guard !FileManager.default.fileExists(atPath: receipt.path) else { return }
        let launcher = """
        #!/bin/bash
        set -euo pipefail
        root="$HOME/.local/share/Steam"
        mkdir -p "$HOME/.steam"
        for mapping in sdkarm64:linuxarm64 sdk64:linux64 sdk32:linux32 bin64:steamrt64 bin32:ubuntu12_32; do
            name=${mapping%%:*}
            target=${mapping#*:}
            if [[ -e "$HOME/.steam/$name" && ! -L "$HOME/.steam/$name" ]]; then
                echo "Refusing to replace existing $HOME/.steam/$name" >&2
                exit 1
            fi
            ln -sfn "$root/$target" "$HOME/.steam/$name"
        done
        export STEAMAC_DXMT_DIR=/etc/steamac/dxmt
        /etc/steamac/bin/steam-gfx-path
        nohup /etc/steamac/bin/steam-gfx-path --watch > "$HOME/.local/share/steamac-dxmt.log" 2>&1 < /dev/null &
        # Rootfs provisioning must never gate native Steam startup.
        mkdir -p "$HOME/.local/share/steamac"
        nohup /etc/steamac/bin/prepare-fex-rootfs > "$HOME/.local/share/steamac/rootfs-install.log" 2>&1 < /dev/null &
        export FEX_ROOTFS="$HOME/.local/share/steamac/fex-rootfs"
        exec /usr/bin/steam-arm64 "$@"
        """
        let hook = """
        #!/bin/sh
        set -eu
        mkdir -p /sysroot/etc/steamac/bin /sysroot/etc/environment.d /sysroot/etc/profile.d
        printf '#!/bin/sh\\nexec /etc/steamac/bin/steam-arm64 "$@"\\n' > /sysroot/etc/steamac/bin/steam
        mkdir -p /run/steamac-dxmt-layer
        mount -t erofs -o ro /dev/vdb /run/steamac-dxmt-layer
        mkdir -p /sysroot/etc/steamac/dxmt
        cp -a /run/steamac-dxmt-layer/usr/lib/steamac/dxmt /sysroot/etc/steamac/
        cp /steamac-dxmt-routing /sysroot/etc/steamac/bin/steam-gfx-path
        chmod 755 /sysroot/etc/steamac/bin/steam-gfx-path
        umount /run/steamac-dxmt-layer
        cp /steamac-fex-rootfs /sysroot/etc/steamac/bin/prepare-fex-rootfs
        chmod 755 /sysroot/etc/steamac/bin/prepare-fex-rootfs
        cp /steamac-compat-launcher /sysroot/etc/steamac/bin/steam-arm64
        chmod 755 /sysroot/etc/steamac/bin/steam-arm64
        if [ -f /sysroot/etc/steamac-client ]; then
            sed -i 's|exec /usr/bin/steam-arm64 |exec /etc/steamac/bin/steam-arm64 |' /sysroot/etc/steamac-client
        fi
        chmod 755 /sysroot/etc/steamac/bin/steam
        printf 'PATH=/etc/steamac/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin\\n' > /sysroot/etc/environment.d/91-steamac-path.conf
        printf 'export PATH=/etc/steamac/bin:$PATH\\n' > /sysroot/etc/profile.d/steamac-path.sh
        """
        var archive: [UInt8] = []
        for name in ["var", "var/lib", "var/lib/dracut", "var/lib/dracut/hooks", "var/lib/dracut/hooks/pre-pivot"] {
            Cpio.append(&archive, name: name, mode: 0o040755, ino: 1, data: [])
        }
        Cpio.append(&archive, name: "steamac-dxmt-routing", mode: 0o100755, ino: 5, data: Array(DXMTGuestScript.routing.utf8))
        Cpio.append(&archive, name: "steamac-fex-rootfs", mode: 0o100755, ino: 4, data: Array(FEXRootFS.installer.utf8))
        Cpio.append(&archive, name: "steamac-compat-launcher", mode: 0o100755, ino: 3, data: Array(launcher.utf8) + [10])
        Cpio.append(&archive, name: "var/lib/dracut/hooks/pre-pivot/91-steamac-compat.sh", mode: 0o100755, ino: 2, data: Array(hook.utf8) + [10])
        Cpio.append(&archive, name: "TRAILER!!!", mode: 0, ino: 0, data: [])
        let file = try FileHandle(forWritingTo: initrd)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        try file.write(contentsOf: Data(repeating: 0, count: Int((4 - end % 4) % 4)))
        try file.write(contentsOf: Data(archive))
        try Data("1".utf8).write(to: receipt, options: .atomic)
    }

    static func grow(_ path: String, bytes: Int64) throws -> GPT {
        var table = try GPT.read(path: path, allowAlignedUsableRange: true)
        guard bytes >= Int64(table.sectors * 512), bytes <= 2048 << 30, bytes % (1 << 20) == 0,
              let index = table.entries.indices.max(by: { table.entries[$0].lastLBA < table.entries[$1].lastLBA }),
              table.entries.count == 3,
              table.entries[index].type == UUID(uuidString: "0FC63DAF-8483-4772-8E79-3D69D8477DE4")! else {
            throw OptionError("Unsupported Bazzite disk layout or capacity")
        }
        if bytes == Int64(table.sectors * 512) { return table }
        let fd = open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw OptionError("Cannot resize Bazzite disk") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw OptionError("Cannot enlarge Bazzite disk") }
        // Retire the old backup GPT inside the newly enlarged partition.
        try GPT.pwriteAll(fd, [UInt8](repeating: 0, count: 33 * 512), at: (table.sectors - 33) * 512)
        table.sectors = UInt64(bytes / 512)
        table.entries[index].lastLBA = table.lastUsableLBA
        try table.write(fd: fd)
        return try GPT.read(path: path)
    }

    static func append(to initrd: URL, password: String?) throws {
        let hash = password.flatMap { $0.isEmpty ? nil : SHA512Crypt.hash($0) } ?? ""
        let setup = """
        #!/bin/bash
        set -eu
        resize2fs /dev/vda3
        # The password hash must remain literal.
        # shellcheck disable=SC2016
        \(hash.isEmpty ? ":" : "printf '%s\\n' 'bazzite:\(hash)' | chpasswd -e")
        rm -f /etc/systemd/system/multi-user.target.wants/steamac-firstboot.service
        rm -f /etc/systemd/system/steamac-firstboot.service /etc/steamac-firstboot
        """
        let client = """
        #!/bin/bash
        set -eu
        branch=steamdeck_stable
        flags=(-steamos -steamdeck -tenfoot -nobreakpad)
        read -r -a words < /proc/cmdline
        for word in "${words[@]}"; do
            case "$word" in
                steamac.steam_client=deckbeta) branch=steamdeck_publicbeta ;;
                steamac.steam_client=frame) branch=; flags=(-deckard -vrgamepadui -nobreakpad) ;;
            esac
        done
        mkdir -p "$HOME/.local/share/Steam/package"
        printf '%s\\n' "$branch" > "$HOME/.local/share/Steam/package/beta"
        exec /usr/bin/steam-arm64 "${flags[@]}"
        """
        let service = """
        [Unit]
        Description=Apply Steamac Bazzite disk settings
        After=local-fs.target
        Before=display-manager.service
        [Service]
        Type=oneshot
        ExecStart=/etc/steamac-firstboot
        [Install]
        WantedBy=multi-user.target
        """
        let hook = """
        #!/bin/sh
        set -eu
        # Each newly created disk consumes setup once; later initramfs boots leave it alone.
        if [ ! -e /sysroot/etc/steamac-setup-installed ]; then
            mkdir -p /sysroot/etc/systemd/system/multi-user.target.wants /sysroot/etc/xdg/autostart
            cp /steamac-setup/firstboot /sysroot/etc/steamac-firstboot
            chmod 700 /sysroot/etc/steamac-firstboot
            cp /steamac-setup/service /sysroot/etc/systemd/system/steamac-firstboot.service
            ln -sf ../steamac-firstboot.service /sysroot/etc/systemd/system/multi-user.target.wants/steamac-firstboot.service
            cp /steamac-setup/client /sysroot/etc/steamac-client
            chmod 755 /sysroot/etc/steamac-client
            printf '[Desktop Entry]\\nType=Application\\nName=Steam Big Picture\\nExec=/etc/steamac-client\\nTerminal=false\\nX-KDE-autostart-after=panel\\n' > /sysroot/etc/xdg/autostart/steam-arm64.desktop
            touch /sysroot/etc/steamac-setup-installed
        fi
        """
        var archive: [UInt8] = []
        for name in ["steamac-setup", "var", "var/lib", "var/lib/dracut", "var/lib/dracut/hooks", "var/lib/dracut/hooks/pre-pivot"] {
            Cpio.append(&archive, name: name, mode: 0o040755, ino: 1, data: [])
        }
        for (name, content, mode) in [
            ("steamac-setup/firstboot", setup, UInt32(0o100700)),
            ("steamac-setup/client", client, UInt32(0o100755)),
            ("steamac-setup/service", service, UInt32(0o100644)),
            ("var/lib/dracut/hooks/pre-pivot/90-steamac-setup.sh", hook, UInt32(0o100755))] {
            Cpio.append(&archive, name: name, mode: mode, ino: 2, data: Array(content.utf8) + [10])
        }
        Cpio.append(&archive, name: "TRAILER!!!", mode: 0, ino: 0, data: [])
        // Linux initramfs accepts a sequence of compressed or uncompressed cpio archives.
        let file = try FileHandle(forWritingTo: initrd)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        let padding = (4 - end % 4) % 4
        try file.write(contentsOf: Data(repeating: 0, count: Int(padding)))
        try file.write(contentsOf: Data(archive))
    }
}
