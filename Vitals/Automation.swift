import AppKit
import Carbon.HIToolbox
import Foundation

/// One command language shared by the CLI, `vitals://` URLs and Shortcuts.
///
///     vitals get <cpu|gpu|memory|disk|network|battery|sensors|fans|bluetooth|all> [--json]
///     vitals open [main|cpu|gpu|memory|disk|network|battery|sensors|clock|settings]
///     vitals fan <index> <rpm|auto>
@MainActor
enum Command {
    static let help = """
    Usage:
      vitals get <cpu|gpu|memory|disk|network|battery|sensors|fans|bluetooth|all> [--json]
      vitals open [page]
      vitals fan <index> <rpm|auto>
    """

    static func run(_ args: [String]) -> String {
        guard let verb = args.first?.lowercased() else { return help }
        let rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        let target = rest.first { !$0.hasPrefix("--") }?.lowercased() ?? "all"
        switch verb {
        case "get":
            let values = Self.values(target)
            guard !values.isEmpty else { return "error: unknown value \(target)" }
            if json {
                let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            return values.count == 1 && target != "all" ? "\(values.values.first!)"
                : values.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        case "open":
            Automation.shared.open(page: Page(target == "all" ? "main" : target) ?? .main)
            return "ok"
        case "fan":
            guard rest.count >= 2, let index = Int(rest[0]) else { return "error: vitals fan <index> <rpm|auto>" }
            if rest[1] == "auto" { FanHelper.shared.setAutomatic(index); return "ok" }
            guard let rpm = Double(rest[1]) else { return "error: rpm must be a number" }
            FanHelper.shared.setManual(index, rpm: rpm)
            return FanHelper.shared.error.map { "error: \($0)" } ?? "ok"
        case "render":
            return WidgetRenderer.renderAll(to: rest.first ?? NSTemporaryDirectory() + "vitals-widgets", monitor: Monitor.shared)
        case "help", "-h", "--help":
            return help
        default:
            return "error: unknown command \(verb)\n\(help)"
        }
    }

    /// Flat key → value readings, rounded for scripts.
    static func values(_ target: String) -> [String: Any] {
        let m = Monitor.shared
        func r(_ v: Double, _ places: Double = 10) -> Double { (v * places).rounded() / places }
        var out: [String: Any] = [:]
        let all = target == "all"
        if all || target == "cpu" {
            out["cpu.usage"] = r(m.cpu.total * 100)
            out["cpu.system"] = r(m.cpu.system * 100)
            out["cpu.user"] = r(m.cpu.user * 100)
            out["cpu.load1"] = r(m.cpu.load.0, 100)
            if let t = m.cpu.temperature { out["cpu.temperature"] = r(t) }
            if let f = m.cpu.pFrequency { out["cpu.frequency.p"] = Int(f) }
            if let f = m.cpu.eFrequency { out["cpu.frequency.e"] = Int(f) }
        }
        if all || target == "gpu" {
            out["gpu.usage"] = r(m.gpu.utilization * 100)
            if let t = m.gpu.temperature { out["gpu.temperature"] = r(t) }
        }
        if all || target == "memory" {
            out["memory.used"] = m.memory.used
            out["memory.total"] = m.memory.total
            out["memory.usage"] = r(m.memory.usedFraction * 100)
            out["memory.pressure"] = m.memory.pressureTitle.lowercased()
            out["memory.swap"] = m.memory.swapUsed
        }
        if all || target == "disk" {
            for (i, v) in m.disk.volumes.enumerated() {
                out["disk.\(i).name"] = v.name
                out["disk.\(i).free"] = v.free
                out["disk.\(i).total"] = v.total
            }
            out["disk.read"] = Int(m.disk.readRate)
            out["disk.write"] = Int(m.disk.writeRate)
        }
        if all || target == "network" {
            out["network.down"] = Int(m.network.down)
            out["network.up"] = Int(m.network.up)
            out["network.interface"] = m.network.interface
            if let ip = m.network.localIP { out["network.ip"] = ip }
            if let ip = m.network.publicIP { out["network.publicip"] = ip }
        }
        if all || target == "battery", m.battery.present {
            out["battery.level"] = Int((m.battery.percent * 100).rounded())
            out["battery.charging"] = m.battery.charging
            if let c = m.battery.cycles { out["battery.cycles"] = c }
            if let h = m.battery.health { out["battery.health"] = Int((h * 100).rounded()) }
        }
        if all || target == "sensors" {
            for s in m.sensors { out["sensor.\(s.kind.rawValue).\(s.name.lowercased().replacingOccurrences(of: " ", with: "_"))"] = r(s.value, 100) }
        }
        if all || target == "fans" {
            for f in m.fans { out["fan.\(f.index).rpm"] = Int(f.rpm) }
        }
        if all || target == "bluetooth" {
            for d in m.bluetooth { out["bluetooth.\(d.name.lowercased().replacingOccurrences(of: " ", with: "_"))"] = d.percent }
        }
        return out
    }
}

@MainActor
final class Automation: ObservableObject {
    static let shared = Automation()
    nonisolated static let commandNote = Notification.Name("com.yahyakhamaisi.vitals.command")
    nonisolated static func replyNote(_ token: String) -> Notification.Name { Notification.Name("com.yahyakhamaisi.vitals.reply.\(token)") }

    @Published private(set) var cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/vitals")
    private var hotKey: HotKey?
    /// Set when a page should open the next time the panel appears.
    var pendingPage: Page?

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Self.commandNote, object: nil, queue: .main) { note in
            guard let args = note.userInfo?["args"] as? [String], let token = note.userInfo?["token"] as? String else { return }
            MainActor.assumeIsolated {
                let output = Command.run(args)
                DistributedNotificationCenter.default().postNotificationName(Self.replyNote(token), object: nil,
                                                                             userInfo: ["output": output], deliverImmediately: true)
            }
        }
        updateHotKey()
    }

    func updateHotKey() {
        if Monitor.shared.config.hotKeyEnabled {
            if hotKey == nil {
                hotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey, id: 1) { MenuBarState.shared.openPanel() }
            }
        } else {
            hotKey = nil
        }
    }

    func handle(url: URL) {
        guard url.scheme == "vitals" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "open":
            open(page: items.first { $0.name == "page" }?.value.flatMap(Page.init) ?? .main)
        default:
            break
        }
    }

    func open(page: Page) {
        pendingPage = page
        MenuBarState.shared.openPanel()
    }

    func installCLI() {
        let exe = Bundle.main.executablePath ?? "/Applications/Vitals.app/Contents/MacOS/Vitals"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vitals-cli")
        guard (try? "#!/bin/sh\nexec \"\(exe)\" cli \"$@\"\n".write(to: temp, atomically: true, encoding: .utf8)) != nil else { return }
        let script = "mkdir -p /usr/local/bin && cp '\(temp.path)' /usr/local/bin/vitals && chmod 755 /usr/local/bin/vitals"
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(script)\" with administrator privileges")?.executeAndReturnError(&err)
        cliInstalled = FileManager.default.fileExists(atPath: "/usr/local/bin/vitals")
    }
}

/// `Vitals cli …` forwards a command to the running app and prints the reply.
enum CLIClient {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 2, args[1] == "cli" else { return }
        let command = Array(args.dropFirst(2))
        let token = UUID().uuidString
        var output: String?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: Automation.replyNote(token), object: nil, queue: nil) { note in
            output = note.userInfo?["output"] as? String ?? ""
        }
        center.postNotificationName(Automation.commandNote, object: nil,
                                    userInfo: ["args": command.isEmpty ? ["help"] : command, "token": token],
                                    deliverImmediately: true)
        let deadline = Date().addingTimeInterval(5)
        while output == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        center.removeObserver(observer)
        if let output {
            print(output)
            exit(output.hasPrefix("error") ? 1 : 0)
        }
        FileHandle.standardError.write("Vitals isn't running. Open Vitals and try again.\n".data(using: .utf8)!)
        exit(2)
    }
}

/// A global shortcut through Carbon, which needs no permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let id: UInt32
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = { MainActor.assumeIsolated { action() } }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            guard hotKeyID.id == me.id else { return OSStatus(eventNotHandledErr) }
            me.action()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x5654_4C53), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
