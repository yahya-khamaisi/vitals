import AppKit
import Foundation

/// Manual fan control. Writing fan keys needs root, so Vitals installs a small launch daemon
/// (a root-owned copy of its own binary run with `--fan-daemon`) that accepts a few
/// one-line commands on a local socket and only ever touches fan keys, within each fan's range.
@MainActor
final class FanHelper: ObservableObject {
    static let shared = FanHelper()

    static let label = "com.yahyakhamaisi.vitals.fanhelper"
    static let binary = "/Library/PrivilegedHelperTools/\(label)"
    static let plist = "/Library/LaunchDaemons/\(label).plist"
    static let socketPath = "/var/run/\(label).sock"

    @Published private(set) var installed = FileManager.default.fileExists(atPath: binary)
    @Published private(set) var running = false
    /// Fans currently held at a manual speed, by index.
    @Published private(set) var manual: [Int: Double] = [:]
    @Published var error: String?

    private init() {
        refresh()
    }

    func refresh() {
        installed = FileManager.default.fileExists(atPath: Self.binary)
        running = installed && Self.send("ping") == "ok"
    }

    func setManual(_ index: Int, rpm: Double) {
        guard ensureHelper() else { return }
        let reply = Self.send("manual \(index) \(Int(rpm))")
        if reply == "ok" { manual[index] = rpm; error = nil } else { error = "The fan helper didn't respond (\(reply ?? "no reply"))." }
    }

    func setAutomatic(_ index: Int) {
        manual[index] = nil
        guard running || installed else { return }
        _ = Self.send("auto \(index)")
    }

    /// Hands every fan back to macOS, at quit.
    func releaseAll() {
        guard !manual.isEmpty else { return }
        for i in manual.keys { _ = Self.send("auto \(i)") }
        manual = [:]
    }

    private func ensureHelper() -> Bool {
        refresh()
        if running { return true }
        if !installed {
            error = "Install the fan helper in Settings › Fan Control Helper first."
            return false
        }
        error = "The fan helper is installed but not running. Reinstall it from Settings."
        return false
    }

    // MARK: Install

    func install() {
        let source = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plistText = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(Self.label)</string>
        <key>ProgramArguments</key><array><string>\(Self.binary)</string><string>--fan-daemon</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        </dict></plist>
        """
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.label).plist")
        do { try plistText.write(to: temp, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription; return }
        let script = [
            "launchctl bootout system/\(Self.label) 2>/dev/null; true",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(q(source)) \(q(Self.binary))",
            "chown root:wheel \(q(Self.binary))",
            "chmod 755 \(q(Self.binary))",
            "cp \(q(temp.path)) \(q(Self.plist))",
            "chown root:wheel \(q(Self.plist))",
            "chmod 644 \(q(Self.plist))",
            "launchctl bootstrap system \(q(Self.plist))"
        ].joined(separator: " && ")
        runAsAdmin(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
    }

    func uninstall() {
        releaseAll()
        runAsAdmin("launchctl bootout system/\(Self.label) 2>/dev/null; rm -f \(q(Self.plist)) \(q(Self.binary)) \(q(Self.socketPath))")
        refresh()
    }

    private func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func runAsAdmin(_ shell: String) {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            error = err[NSAppleScript.errorMessage] as? String ?? "Couldn't install the helper."
        } else {
            error = nil
        }
    }

    // MARK: Socket client

    nonisolated static func send(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketPath.utf8.prefix(raw.count - 1).enumerated() { raw[i] = b }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let message = line + "\n"
        _ = message.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return String(decoding: buffer.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Daemon (runs as root)

    nonisolated static func runDaemonIfRequested() {
        guard CommandLine.arguments.contains("--fan-daemon") else { return }
        guard getuid() == 0 else {
            FileHandle.standardError.write("The fan helper must run as root.\n".data(using: .utf8)!)
            exit(1)
        }
        let smc = SMC.shared
        let reader = SensorReader()
        unlink(socketPath)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in socketPath.utf8.prefix(raw.count - 1).enumerated() { raw[i] = b }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 4) == 0 else { exit(1) }
        chmod(socketPath, 0o666)

        func restoreAll() {
            for fan in reader.readFans() { _ = smc.write(reader.modeKey(fan.index), number: 0) }
            _ = smc.write("Ftst", number: 0)
        }
        signal(SIGTERM) { _ in
            let smc = SMC.shared, reader = SensorReader()
            for fan in reader.readFans() { _ = smc.write(reader.modeKey(fan.index), number: 0) }
            exit(0)
        }

        while true {
            let client = accept(server, nil, nil)
            guard client >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 128)
            let n = read(client, &buffer, buffer.count)
            var reply = "error"
            if n > 0 {
                let parts = String(decoding: buffer.prefix(n), as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
                let fans = reader.readFans()
                switch (parts.first, parts.count) {
                case ("ping", _):
                    reply = "ok"
                case ("auto", 2):
                    if let i = Int(parts[1]), fans.contains(where: { $0.index == i }) {
                        reply = smc.write(reader.modeKey(i), number: 0) ? "ok" : "error write"
                        if reader.readFans().allSatisfy({ !$0.manual }) { _ = smc.write("Ftst", number: 0) }
                    }
                case ("manual", 3):
                    if let i = Int(parts[1]), let rpm = Double(parts[2]), let fan = fans.first(where: { $0.index == i }) {
                        let clamped = min(fan.max, max(fan.min, rpm))
                        _ = smc.write("Ftst", number: 1)
                        let mode = smc.write(reader.modeKey(i), number: 1)
                        let target = smc.write("F\(i)Tg", number: clamped)
                        reply = mode && target ? "ok" : "error write"
                    }
                case ("restore", _):
                    restoreAll()
                    reply = "ok"
                default:
                    break
                }
            }
            _ = (reply + "\n").withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }
}
