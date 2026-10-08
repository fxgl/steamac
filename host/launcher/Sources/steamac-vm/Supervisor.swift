import Darwin
import Foundation

/// The process the user starts. libkrun ends a VM by `_exit()`ing its process (power-off *and*
/// reboot), so each boot runs in a child process (`STEAMAC_VM_CHILD=1`, same argv) while this
/// supervisor stays in the foreground: it owns gvproxy (restarted per boot), restores the
/// terminal, forwards signals, cleans up, and relaunches the VM when the child left a reboot
/// marker (guest-initiated restart).
enum Supervisor {
    static let childEnv = "STEAMAC_VM_CHILD"
    static let runDirEnv = "STEAMAC_RUN_DIR"
    static let netSockEnv = "STEAMAC_NET_SOCK"
    static let bootEnv = "STEAMAC_BOOT"
    static let frameEnv = "STEAMAC_WINDOW_FRAME"

    static var isChild: Bool { ProcessInfo.processInfo.environment[childEnv] == "1" }
    static var runDir: String? { ProcessInfo.processInfo.environment[runDirEnv] }
    static var netSocket: String? { ProcessInfo.processInfo.environment[netSockEnv] }
    static var bootNumber: Int { Int(ProcessInfo.processInfo.environment[bootEnv] ?? "1") ?? 1 }
    static var windowFrame: String? { ProcessInfo.processInfo.environment[frameEnv] }
    static func rebootMarker(_ dir: String) -> String { dir + "/reboot" }

    nonisolated(unsafe) private static var childPid: pid_t = 0
    /// The running VM process (0 between boots).
    static var vmPid: pid_t { childPid }
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []

    /// Remove /tmp/steamac-<pid> run dirs whose launcher is gone (left behind by kill -9).
    /// Only our own directories qualify; a pid that is alive (even if reused) is left alone.
    private static func sweepStaleRunDirs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        var removed: [String] = []
        for name in entries where name.hasPrefix("steamac-") {
            guard let pid = pid_t(name.dropFirst("steamac-".count)), pid > 0 else { continue }
            let path = "/tmp/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { continue }
            guard kill(pid, 0) == -1 && errno == ESRCH else { continue }
            if (try? fm.removeItem(atPath: path)) != nil { removed.append(path) }
        }
        if !removed.isEmpty {
            log("removed stale run dir\(removed.count == 1 ? "" : "s") of dead launchers: \(removed.joined(separator: ", "))")
        }
    }

    /// `resolve` reads the command line + saved settings again before every boot, so next-start
    /// settings changed in the Settings window ("Restart VM to apply") take effect on relaunch.
    static func run(resolve: () throws -> Options) -> Never {
        sweepStaleRunDirs()
        // sun_path is 104 bytes on macOS: keep the run dir short.
        let dir = "/tmp/steamac-\(getpid())"
        try? FileManager.default.removeItem(atPath: dir)
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            fatal("cannot create \(dir): \(error)")
        }
        RollingLog.launcher.open(dir: dir)

        var savedTermios: termios?
        if Console.ownsTerminal {
            var t = termios()
            if tcgetattr(STDIN_FILENO, &t) == 0 { savedTermios = t }
        }

        var gvproxy: Gvproxy?
        var remotePlay: RemotePlayRelay?

        func cleanup() {
            remotePlay?.stop()
            gvproxy?.stop()
            try? FileManager.default.removeItem(atPath: dir)
            if var t = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &t) }
        }

        // Forward termination/dump signals to the VM process (it implements the policy:
        // first request = guest power key, a later one = force quit). Without one (the offer
        // after an unexpected exit is up) a termination signal closes that offer.
        let queue = DispatchQueue(label: "steamac.signals")
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            s.setEventHandler {
                if childPid > 0 { kill(childPid, sig) }
                else if sig != SIGUSR1 { DispatchQueue.main.async { MainActor.assumeIsolated { CrashOffer.dismiss() } } }
            }
            s.resume()
            signalSources.append(s)
        }

        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var boot = 1
        var frame: String?
        while true {
            let o: Options
            do {
                o = try resolve()
            } catch {
                log("error: \(error)")
                cleanup()
                exit(2)
            }
            // Another launcher's VM writing this disk: refuse before anything starts (the VM process
            // holds the lock; see DiskLock).
            if let busy = o.disks.first(where: { !$0.readOnly && DiskLock.inUse($0.path) }) {
                let error = DiskLock.InUse(path: busy.path)
                log("error: \(error)")
                MainActor.assumeIsolated { AppBundle.alertIfLaunchedFromFinder("SteamOS is already running", error.localizedDescription) }
                cleanup()
                exit(1)
            }
            do {
                try DiskGrower.applyPending(runDir: dir, disks: o.disks)
            } catch {
                log("grow-disk: \(error)")
                MainActor.assumeIsolated { AppBundle.alertIfLaunchedFromFinder("SteamOS disk could not be grown", error.localizedDescription) }
                cleanup()
                exit(1)
            }
            // No disk yet (app bundle first run): the VM process shows the first-run sheet instead.
            gvproxy = nil
            if o.network && !o.needsDisk {
                guard let bin = Gvproxy.locate(explicit: o.gvproxyPath) else {
                    log("error: gvproxy not found (run host/launcher/fetch-gvproxy.sh, pass --gvproxy PATH, or --no-net)")
                    cleanup()
                    exit(1)
                }
                let g = Gvproxy(runDir: dir)
                gvproxy = g
                do {
                    try g.start(binary: bin, sshPort: o.sshPort)
                } catch {
                    log("error: \(error)")
                    cleanup()
                    exit(1)
                }
                if o.lanRemotePlay {
                    let relay = RemotePlayRelay(proxy: g)
                    do {
                        try relay.start()
                        remotePlay = relay
                    } catch {
                        log("remote-play: disabled for this boot: \(error); port conflict or Local Network/firewall permission may block discovery")
                    }
                }
            }
            var env = ProcessInfo.processInfo.environment
            env[childEnv] = "1"
            env[runDirEnv] = dir
            env[bootEnv] = String(boot)
            env[netSockEnv] = gvproxy?.vfkitSocket
            env[frameEnv] = frame
            CrashReporting.supervisorBoot(o, boot: boot, runDir: dir, env: &env)
            let vmExit = spawnAndWait(exe, CommandLine.arguments, env)
            let status = vmExit.status
            childPid = 0
            if var t = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &t) }
            remotePlay?.stop()
            remotePlay = nil
            gvproxy?.stop()
            if CrashReporting.terminationSignals.contains(vmExit.signal) {
                log("VM process terminated by \(CrashReporting.signalName(vmExit.signal)) (a termination request, not a crash)")
            } else if vmExit.signal == SIGPIPE {
                log("VM process ended by SIGPIPE (an output pipe closed; not a crash)")
            }
            CrashReporting.vmExited(vmExit)

            let marker = rebootMarker(dir)
            if let contents = try? String(contentsOfFile: marker, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: marker)
                let text = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if text == firstRunMarker {
                    log("disk image chosen: starting the VM")
                    continue
                }
                boot += 1
                frame = text
                log("guest rebooted (VM exit status \(status)): starting boot #\(boot)")
                continue
            }
            // Unexpected exit (crash, error): offer Report a Problem before cleaning up (the
            // report reads this session's logs from the run dir).
            if CrashReporting.unexpectedExit(status: status, runDir: dir), CrashOffer.wanted(o) {
                MainActor.assumeIsolated { CrashOffer.run(status: status, options: o, runDir: dir) }
            }
            cleanup()
            exit(status)
        }
    }

    /// Reboot-marker contents written by the first-run sheet (not a reboot: boot number unchanged).
    static let firstRunMarker = "firstrun"

    /// posix_spawn (same process group, so the VM process can own the terminal) + waitpid. The
    /// exit details (jetsam) and final memory footprint are read from the zombie before reaping.
    private static func spawnAndWait(_ exe: String, _ argv: [String], _ env: [String: String]) -> VMExit {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Default signal dispositions in the child (we ignore the forwarded ones here). SIGPIPE
        // stays ignored, as in this process (main.swift).
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGUSR1] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var noMask = sigset_t()
        sigemptyset(&noMask)
        posix_spawnattr_setsigmask(&attr, &noMask)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, cArgs, cEnv)
        guard rc == 0 else {
            log("error: cannot start VM process: \(String(cString: strerror(rc)))")
            return VMExit(status: 1)
        }
        childPid = pid
        var exit = VMExit(status: 1)
        // NOTE_EXIT fires when the process becomes a zombie; its data carries NOTE_EXIT_DETAIL
        // bits (NOTE_EXIT_MEMORY = jetsam, the kernel's jetsam cause in the high bits). Not
        // registered if it already exited (ESRCH).
        let kq = kqueue()
        if kq >= 0 {
            var change = Darwin.kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                       fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXIT_DETAIL), data: 0, udata: nil)
            if kevent(kq, &change, 1, nil, 0, nil) == 0 {
                var event = Darwin.kevent()
                var n: Int32
                repeat { n = kevent(kq, nil, 0, &event, 1, nil) } while n < 0 && errno == EINTR
                if n == 1 && event.fflags & UInt32(NOTE_EXIT_DETAIL) != 0 {
                    exit.detail = UInt32(truncatingIfNeeded: event.data)
                }
            }
            close(kq)
        }
        exit.peakFootprint = VMExit.footprint(pid: pid)?.peak
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return exit }
        }
        // WIFEXITED / WEXITSTATUS / WTERMSIG (macros are not imported into Swift).
        let low = status & 0x7f
        exit.status = low == 0 ? (status >> 8) & 0xff : 128 + low
        return exit
    }
}
