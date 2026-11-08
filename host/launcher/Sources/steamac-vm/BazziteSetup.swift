import Darwin
import Foundation

/// Per-disk first-boot configuration appended to Fedora's initramfs. Passwords
/// are hashed on the Mac; no plaintext is written to the guest or the sidecar.
enum BazziteSetup {
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
        # shellcheck disable=SC2016 -- the password hash must remain literal
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
