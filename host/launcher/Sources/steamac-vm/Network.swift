import CKrun
import Darwin
import Foundation

/// gvproxy (containers/gvisor-tap-vsock) in vfkit unixgram mode backing virtio-net.
/// Guest MAC 5a:94:ef:e4:0c:ee is gvproxy's built-in static DHCP lease -> 192.168.127.2,
/// which is also the target of its -ssh-port forward (127.0.0.1:PORT -> guest :22).
/// Owned by the supervisor process (it outlives each VM process), restarted for every boot.
final class Gvproxy {
    static let guestMAC: [UInt8] = [0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee]
    let runDir: String
    let vfkitSocket: String
    let apiSocket: String
    private var process: Process?
    /// Write end of the guard's lifeline pipe (closing it also stops gvproxy).
    private var lifeline: Pipe?

    init(runDir: String) {
        self.runDir = runDir
        vfkitSocket = runDir + "/net.sock"
        apiSocket = runDir + "/api.sock"
    }

    static func locate(explicit: String?) -> String? {
        if let explicit { return explicit }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let exeDir = exe.resolvingSymlinksInPath().deletingLastPathComponent().path
        let candidates = [
            exeDir + "/host/bin/gvproxy",
            "/opt/homebrew/opt/podman/libexec/podman/gvproxy",
            "/opt/homebrew/libexec/podman/gvproxy",
            "/opt/homebrew/bin/gvproxy",
            "/usr/local/bin/gvproxy",
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gvproxy" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(binary: String, sshPort: Int) throws {
        try? FileManager.default.removeItem(atPath: vfkitSocket)
        try? FileManager.default.removeItem(atPath: apiSocket)
        // gvproxy runs under a tiny /bin/sh guard holding the read end of a pipe whose only writer
        // is this process: if the launcher dies in any way (even SIGKILL), the guard sees EOF and
        // kills gvproxy, so its ssh port is never left bound by an orphan. SIGTERM (stop()) is
        // forwarded and waited for.
        let guardScript = """
        exec 3<&0
        "$@" </dev/null >/dev/null 2>&1 3<&- &
        p=$!
        trap 'kill $p 2>/dev/null; wait $p; exit 0' TERM INT HUP
        # (async lists get stdin from /dev/null, so the lifeline is read via fd 3)
        ( while read -r _ <&3; do :; done; kill $p 2>/dev/null ) &
        wait $p
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", guardScript, "gvproxy", binary,
            "-listen-vfkit", "unixgram://" + vfkitSocket,
            "-listen", "unix://" + apiSocket,
            "-ssh-port", String(sshPort == 0 ? -1 : sshPort),
            "-log-file", runDir + "/gvproxy.log",
            "-pid-file", runDir + "/gvproxy.pid",
        ]
        let lifeline = Pipe()
        _ = fcntl(lifeline.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        p.standardInput = lifeline
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        try? lifeline.fileHandleForReading.close()
        process = p
        self.lifeline = lifeline
        // Wait for the vfkit socket (libkrun connects to it when the net device is created).
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: vfkitSocket) {
            guard p.isRunning else {
                // The run dir is removed on exit, so surface gvproxy's own error now.
                let tail = ((try? String(contentsOfFile: runDir + "/gvproxy.log", encoding: .utf8)) ?? "")
                    .split(separator: "\n").suffix(3).joined(separator: "\n  ")
                throw OptionError("gvproxy exited (status \(p.terminationStatus))"
                    + (sshPort == 0 ? "" : " — is 127.0.0.1:\(sshPort) already in use? (--ssh-port)") + "\n  \(tail)")
            }
            guard Date() < deadline else { throw OptionError("gvproxy did not create \(vfkitSocket)") }
            usleep(20_000)
        }
        let pid = (try? String(contentsOfFile: runDir + "/gvproxy.pid", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        log("network: gvproxy \(binary) pid \(pid), guest 192.168.127.2"
            + (sshPort == 0 ? "" : ", ssh -p \(sshPort) <user>@127.0.0.1") + ", API unix://\(apiSocket)")
    }

    /// gvproxy's HTTP control API. Only startup/teardown calls use curl; packet traffic
    /// stays on nonblocking UDP sockets, not subprocesses.
    func forward(protocol transport: String, local: String, remote: String?) throws {
        var request = ["protocol": transport, "local": local]
        if let remote { request["remote"] = remote }
        let body = try JSONSerialization.data(withJSONObject: request)
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--silent", "--show-error", "--fail-with-body", "--max-time", "3",
                       "--unix-socket", apiSocket, "-H", "Content-Type: application/json",
                       "-d", String(decoding: body, as: UTF8.self),
                       "http://localhost/services/forwarder/" + (remote == nil ? "unexpose" : "expose")]
        p.standardOutput = output; p.standardError = output
        try p.run()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw OptionError("gvproxy \(transport) \(local): \(String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Read-only, on-demand report probe: distinguish lost forwards/API from an idle Steam.
    static func forwardingDiagnostics(runDir: String) -> String {
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["--silent", "--show-error", "--fail-with-body", "--max-time", "2",
                       "--unix-socket", runDir + "/api.sock", "http://localhost/services/forwarder/all"]
        p.standardOutput = output; p.standardError = output
        do { try p.run() }
        catch { return "gvproxy forward API unavailable: \(error)\n" }
        let response = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: response.prefix(64 << 10), as: UTF8.self)
        return "gvproxy forward API exit: \(p.terminationStatus)\n" + text + "\n"
    }

    /// The VM's end of gvproxy's vfkit socket cannot be created: the volume holding the run
    /// directory is full. An expected host condition, refused before the VM starts (STEAMAC-82:
    /// libkrun's own bind failed with ENOSPC at virtio-net activation and panicked).
    struct NoSpace: LocalizedError, CustomStringConvertible {
        let path: String
        var description: String {
            "Cannot create the VM's network socket \(path): no space left on the Mac's startup disk. Free some space on the startup disk, then start FX Steam Launcher again."
        }
        var errorDescription: String? {
            String(localized: "Cannot create the VM's network socket \(path): no space left on the Mac's startup disk. Free some space on the startup disk, then start FX Steam Launcher again.")
        }
    }

    /// libkrun's frame and receive buffer sizes for unixgram backends (devices/src/virtio/net/
    /// unixgram.rs on macOS: SO_SNDBUF is the maximum frame, MAX_BUFFER_SIZE - VNET_HDR_LEN).
    static let socketSendBuffer: Int32 = 65562 - 12
    static let socketReceiveBuffer: Int32 = 7 * 1024 * 1024

    /// Connects the VM's end before the VM starts and hands libkrun the descriptor: libkrun would
    /// otherwise bind and connect only when the guest activates virtio-net, and turn any failure
    /// there (no space for the socket, gvproxy gone) into a Rust panic (STEAMAC-82). The local
    /// socket lives next to gvproxy's, in the run directory removed on exit.
    static func attach(ctx: UInt32, socket: String) throws {
        let fd = try connect(peer: socket, local: (socket as NSString).deletingLastPathComponent + "/vm-net-\(getpid()).sock")
        var mac = Gvproxy.guestMAC
        // libkrun owns the descriptor from here (it closes it with the device).
        let r = krun_add_net_unixgram(ctx, nil, fd, &mac, STEAMAC_COMPAT_NET_FEATURES, 0)
        if r < 0 {
            close(fd)
            throw KrunError(call: "krun_add_net_unixgram", code: r)
        }
    }

    /// A unixgram socket bound at `local`, connected to gvproxy's vfkit socket `peer`, after the
    /// vfkit handshake, with libkrun's buffer sizes.
    static func connect(peer: String, local: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw OptionError("network: socket: \(String(cString: strerror(errno)))") }
        var ok = false
        defer { if !ok { close(fd) } }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        func address(_ path: String) throws -> sockaddr_un {
            var a = sockaddr_un()
            a.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { throw OptionError("network: socket path too long: \(path)") }
            withUnsafeMutableBytes(of: &a.sun_path) { $0.copyBytes(from: bytes) }
            a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            return a
        }
        var localAddress = try address(local)
        unlink(local)
        let bound = withUnsafePointer(to: &localAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            if error == ENOSPC { throw NoSpace(path: local) }
            throw OptionError("network: bind \(local): \(String(cString: strerror(error)))")
        }
        var peerAddress = try address(peer)
        let connected = withUnsafePointer(to: &peerAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = errno
            // gvproxy created the socket and has since exited or removed it: its log says why.
            let tail = ((try? String(contentsOfFile: (peer as NSString).deletingLastPathComponent + "/gvproxy.log", encoding: .utf8)) ?? "")
                .split(separator: "\n").suffix(5).joined(separator: "\n  ")
            throw OptionError("network: connect to gvproxy \(peer): \(String(cString: strerror(error)))"
                + (tail.isEmpty ? " (no gvproxy log)" : "; gvproxy log:\n  \(tail)"))
        }
        let magic: [UInt8] = Array("VFKT".utf8)
        guard Darwin.send(fd, magic, magic.count, 0) == magic.count else {
            throw OptionError("network: vfkit handshake with \(peer): \(String(cString: strerror(errno)))")
        }
        var send = socketSendBuffer, receive = socketReceiveBuffer
        if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size)) != 0
            || setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            log("network: socket buffer sizes not applied: \(String(cString: strerror(errno)))")
        }
        ok = true
        return fd
    }

    /// Stop gvproxy and wait until it is gone (its ssh port is free again afterwards).
    func stop() {
        guard let p = process else { return }
        process = nil
        defer {
            try? lifeline?.fileHandleForWriting.close()
            lifeline = nil
        }
        guard p.isRunning else { return }
        kill(p.processIdentifier, SIGTERM)   // guard forwards it to gvproxy and waits for it
        for _ in 0..<300 where p.isRunning { usleep(10_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
    }
}
