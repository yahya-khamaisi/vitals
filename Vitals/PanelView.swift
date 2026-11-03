import AppKit
import SwiftUI

enum Page: Hashable {
    case main
    case module(Module)
    case settings, widgets, alerts, fanHelper, automation, about

    init?(_ name: String) {
        if let m = Module(rawValue: name) { self = .module(m); return }
        switch name {
        case "main": self = .main
        case "settings": self = .settings
        case "widgets": self = .widgets
        case "alerts": self = .alerts
        case "fans", "fanHelper": self = .fanHelper
        case "automation": self = .automation
        case "about": self = .about
        default: return nil
        }
    }
}

/// Simple push/pop navigation inside the one menu-bar panel. No windows.
final class Navigator: ObservableObject {
    @Published var stack: [Page]
    /// The module the menu-bar editor opens on.
    var focus: Module?
    init(_ start: Page) { stack = [start] }
    var current: Page { stack.last ?? .main }
    func push(_ p: Page) { withAnimation(.snappy(duration: 0.25)) { stack.append(p) } }
    func pop() {
        withAnimation(.snappy(duration: 0.25)) {
            if stack.count > 1 { stack.removeLast() } else if stack.first != .main { stack = [.main] }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var monitor: Monitor
    @StateObject private var nav: Navigator

    init(initialPage: Page = .main) {
        _nav = StateObject(wrappedValue: Navigator(initialPage))
    }

    var body: some View {
        Group {
            switch nav.current {
            case .main: MainPage()
            case .module(let m): ModulePage(module: m)
            case .settings: SettingsPage()
            case .widgets: WidgetsPage()
            case .alerts: AlertsPage()
            case .fanHelper: FanHelperPage()
            case .automation: AutomationPage()
            case .about: AboutPage()
            }
        }
        .id(nav.current)
        .transition(.opacity)
        .environmentObject(nav)
        .frame(width: Metrics.width)
        .focusEffectDisabled()
        .onAppear {
            if let page = Automation.shared.pendingPage {
                Automation.shared.pendingPage = nil
                nav.stack = page == .main ? [.main] : [.main, page]
            }
        }
    }
}

struct ModulePage: View {
    let module: Module
    var body: some View {
        switch module {
        case .cpu: CPUPage()
        case .gpu: GPUPage()
        case .memory: MemoryPage()
        case .disk: DiskPage()
        case .network: NetworkPage()
        case .battery, .bluetooth: BatteryPage()
        case .sensors: SensorsPage()
        case .clock: ClockPage()
        }
    }
}

// MARK: - Main page

struct MainPage: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var nav: Navigator

    var body: some View {
        PageScroll {
            header
            gauges
            if monitor.config.isOn(.network) { network }
            rows
            processes
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Vitals").font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HeaderButton(symbol: "waveform.path.ecg", label: "Open Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            HeaderButton(symbol: "gearshape", label: "Settings") { nav.push(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            HeaderButton(symbol: "power", label: "Quit Vitals") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 2)
        .frame(height: 32)
    }

    private var subtitle: String {
        let model = Host.modelName
        let chip = monitor.cpu.name.isEmpty ? "" : " · \(monitor.cpu.name.replacingOccurrences(of: "Apple ", with: ""))"
        return "\(model)\(chip) · up \(Format.shortDuration(monitor.cpu.uptime))"
    }

    private var gauges: some View {
        Card(padded: true) {
            HStack(spacing: 4) {
                if monitor.config.isOn(.cpu) { RingGauge(label: "CPU", value: monitor.cpu.total, tint: Module.cpu.tint) }
                if monitor.config.isOn(.gpu) { RingGauge(label: "GPU", value: monitor.gpu.utilization, tint: Module.gpu.tint) }
                if monitor.config.isOn(.memory) { RingGauge(label: "Memory", value: monitor.memory.usedFraction, tint: Module.memory.tint) }
                if monitor.config.isOn(.disk) { RingGauge(label: "Disk", value: monitor.disk.mainUsedFraction, tint: Module.disk.tint) }
            }
            .padding(.vertical, 2)
        }
    }

    private var network: some View {
        Button { nav.push(.module(.network)) } label: {
            Card(padded: true) {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Network · \(monitor.network.kind)").fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        Text("↓ \(Format.rate(monitor.network.down))").fontWeight(.semibold).foregroundStyle(.blue)
                        Text("↑ \(Format.rate(monitor.network.up))").fontWeight(.semibold).foregroundStyle(.orange)
                    }
                    .font(.system(size: 11)).monospacedDigit()
                    .frame(height: 14)
                    AreaChart(layers: [.init(values: monitor.series(.netDown), tint: .blue, fill: false),
                                       .init(values: monitor.series(.netUp), tint: .orange, fill: false)], max: nil, gridLines: 0)
                        .frame(height: 40)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Network, down \(Format.rate(monitor.network.down)), up \(Format.rate(monitor.network.up))")
    }

    private var rows: some View {
        Card {
            ForEach(monitor.config.order.filter { monitor.config.isOn($0) }) { m in
                NavRow(symbol: m.symbol, tint: m.tint, title: m.title, value: summary(m)) { nav.push(.module(m)) }
            }
        }
    }

    private func summary(_ m: Module) -> String {
        switch m {
        case .cpu: return Format.percent(monitor.cpu.total) + (monitor.cpu.pFrequency.map { " · " + Format.frequency($0) } ?? "")
        case .gpu: return Format.percent(monitor.gpu.utilization) + (monitor.gpu.temperature.map { " · " + Format.temperature($0) } ?? "")
        case .memory: return "\(Format.memory(monitor.memory.used)) of \(Format.memory(monitor.memory.total))"
        case .disk: return monitor.disk.volumes.first.map { "\(Format.bytes($0.free)) free" } ?? ""
        case .network: return monitor.network.localIP ?? monitor.network.kind
        case .battery:
            let b = monitor.battery
            guard b.present else { return "No battery" }
            let time = b.minutesRemaining.map { " · \(Format.minutes($0))" + (b.charging ? " to full" : " left") } ?? (b.pluggedIn ? " · on power" : "")
            return Format.percent(b.percent) + time
        case .sensors:
            let fan = monitor.fans.first.map { " · \(Int($0.rpm).formatted()) rpm" } ?? ""
            return Format.temperature(monitor.hottest) + fan
        case .bluetooth: return monitor.bluetooth.isEmpty ? "No devices" : "\(monitor.bluetooth.count) device\(monitor.bluetooth.count == 1 ? "" : "s")"
        case .clock: return monitor.config.clocks.prefix(2).map(\.label).joined(separator: " · ")
        }
    }

    private var processes: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Top processes").fontWeight(.semibold)
                Spacer()
                Text("CPU").frame(width: 44, alignment: .trailing)
                Text("Memory").frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.inset)
            .frame(height: 14)
            Card {
                ForEach(monitor.topByCPU.prefix(3)) { p in
                    HStack(spacing: 8) {
                        ProcessIcon(pid: p.pid, name: p.name)
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f%%", p.cpu)).frame(width: 44, alignment: .trailing)
                        Text(Format.memory(p.memory)).frame(width: 56, alignment: .trailing)
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Metrics.inset)
                    .frame(height: Metrics.row)
                }
            }
        }
    }
}

struct HeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 14, height: 14)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .help(label)
        .accessibilityLabel(label)
    }
}

enum Host {
    private static let key = "host.modelName"

    /// "MacBook Pro". Newer models only say "Mac17,2" in sysctl, so the marketing name comes
    /// from System Profiler once, in the background, and is remembered.
    static var modelName: String {
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let id = Sys.string("hw.model") ?? ""
        return id.hasPrefix("MacBookPro") ? "MacBook Pro" : id.hasPrefix("MacBookAir") ? "MacBook Air" : id.hasPrefix("Macmini") ? "Mac mini" : "Mac"
    }

    static func resolveModelName() {
        guard UserDefaults.standard.string(forKey: key) == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let out = Sys.run("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"], timeout: 15),
                  let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
                  let item = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
                  let name = item["machine_name"] as? String, !name.isEmpty else { return }
            UserDefaults.standard.set(name, forKey: key)
        }
    }
}
