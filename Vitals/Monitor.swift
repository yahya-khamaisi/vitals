import AppKit
import Combine
import Foundation
import UserNotifications

/// A fixed-length series for charts, newest value last.
struct History: Equatable {
    static let length = 60
    private(set) var values: [Double] = Array(repeating: 0, count: length)
    mutating func append(_ v: Double) {
        values.append(v.isFinite ? v : 0)
        if values.count > Self.length { values.removeFirst(values.count - Self.length) }
    }
    var last: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
}

enum Series: String, CaseIterable {
    case cpuTotal, cpuSystem, gpu, memory, pressure, netDown, netUp, diskRead, diskWrite
}

/// Samples every module on a background queue and publishes the results for the panel and menu bar.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published var config = Config.load() {
        didSet {
            guard config != oldValue else { return }
            config.save()
            if config.interval != oldValue.interval { restartTimer() }
            onConfigChange?()
        }
    }

    @Published private(set) var cpu = CPUStats()
    @Published private(set) var gpu = GPUStats()
    @Published private(set) var memory = MemoryStats()
    @Published private(set) var disk = DiskStats()
    @Published private(set) var network = NetworkStats()
    @Published private(set) var battery = BatteryStats()
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var fans: [Fan] = []
    @Published private(set) var bluetooth: [BluetoothDevice] = []
    @Published private(set) var processes: [ProcessUsage] = []
    @Published private(set) var netProcesses: [NetProcess] = []
    @Published private(set) var history: [Series: History] = Dictionary(uniqueKeysWithValues: Series.allCases.map { ($0, History()) })

    /// Called after each sample so the menu bar can redraw.
    var onSample: (() -> Void)?
    var onConfigChange: (() -> Void)?
    /// Set while the Network page is open; per-process traffic is costly to measure.
    var watchNetworkProcesses = false

    private let queue = DispatchQueue(label: "vitals.sampler", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var ticks = 0

    // Readers are only touched on `queue`.
    nonisolated(unsafe) private let cpuReader = CPUReader()
    nonisolated(unsafe) private let ioReport = IOReport()
    nonisolated(unsafe) private let sensorReader = SensorReader()
    nonisolated(unsafe) private let diskReader = DiskReader()
    nonisolated(unsafe) private let networkReader = NetworkReader()
    nonisolated(unsafe) private let bluetoothReader = BluetoothReader()
    nonisolated(unsafe) private var cpuScratch = CPUStats()
    nonisolated(unsafe) private var gpuScratch = GPUStats()

    private var alertSince: [UUID: Date] = [:]
    private var alertFired: Set<UUID> = []

    func start() {
        sample()
        restartTimer()
        UNUserNotificationCenter.current().getNotificationSettings { _ in }
    }

    func stop() { timer?.invalidate() }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(0.5, config.interval), repeats: true) { _ in
            MainActor.assumeIsolated { Monitor.shared.sample() }
        }
        timer?.tolerance = 0.1
    }

    struct Snapshot {
        var cpu: CPUStats
        var gpu: GPUStats
        var memory: MemoryStats
        var disk: DiskStats
        var network: NetworkStats
        var battery: BatteryStats
        var sensors: [SensorReading]
        var fans: [Fan]
        var bluetooth: [BluetoothDevice]?
        var processes: [ProcessUsage]?
        var netProcesses: [NetProcess]?
    }

    func sample() {
        guard !sampling else { return }
        sampling = true
        ticks += 1
        let tick = ticks
        let config = config
        let watchNet = watchNetworkProcesses
        queue.async { [self] in
            let snapshot = gather(tick: tick, config: config, watchNet: watchNet)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.apply(snapshot) } }
        }
    }

    nonisolated private func gather(tick: Int, config: Config, watchNet: Bool) -> Snapshot {
        cpuReader.read(into: &cpuScratch)
        GPUReader.read(into: &gpuScratch)
        let report = ioReport.sample()
        cpuScratch.eFrequency = report?.eFrequency
        cpuScratch.pFrequency = report?.pFrequency
        cpuScratch.watts = report?.cpuWatts
        gpuScratch.frequency = report?.gpuFrequency
        gpuScratch.watts = report?.gpuWatts

        let sensors = sensorReader.readSensors(cpuWatts: report?.cpuWatts, gpuWatts: report?.gpuWatts, aneWatts: report?.aneWatts)
        func temp(_ names: [String]) -> Double? {
            names.lazy.compactMap { n in sensors.first { $0.kind == .temperature && $0.name == n }?.value }.first
        }
        cpuScratch.temperature = temp(["CPU performance cores", "CPU die", "SoC", "CPU efficiency cores"])
        gpuScratch.temperature = temp(["GPU"])
        var battery = BatteryReader.read()
        if battery.temperature == nil { battery.temperature = temp(["Battery"]) }

        return Snapshot(cpu: cpuScratch, gpu: gpuScratch, memory: MemoryReader.read(), disk: diskReader.read(),
                        network: networkReader.read(lookUpPublicIP: config.lookUpPublicIP), battery: battery,
                        sensors: sensors, fans: sensorReader.readFans(),
                        bluetooth: config.isOn(.bluetooth) && (tick == 1 || tick % 10 == 0) ? bluetoothReader.read() : nil,
                        processes: tick == 1 || tick % 2 == 0 ? ProcessReader.read() : nil,
                        netProcesses: watchNet && tick % 3 == 0 ? NetworkReader.processes() : nil)
    }

    private func apply(_ s: Snapshot) {
        sampling = false
        cpu = s.cpu
        gpu = s.gpu
        memory = s.memory
        disk = s.disk
        network = s.network
        battery = s.battery
        sensors = s.sensors
        fans = s.fans
        if let b = s.bluetooth { bluetooth = b }
        if let p = s.processes { processes = p }
        if let n = s.netProcesses { netProcesses = n }
        var h = history
        h[.cpuTotal]?.append(s.cpu.total)
        h[.cpuSystem]?.append(s.cpu.system)
        h[.gpu]?.append(s.gpu.utilization)
        h[.memory]?.append(s.memory.usedFraction)
        h[.pressure]?.append(s.memory.pressure)
        h[.netDown]?.append(s.network.down)
        h[.netUp]?.append(s.network.up)
        h[.diskRead]?.append(s.disk.readRate)
        h[.diskWrite]?.append(s.disk.writeRate)
        history = h
        checkAlerts()
        onSample?()
    }

    func series(_ s: Series) -> [Double] { history[s]?.values ?? [] }

    func resetNetworkToday() { queue.async { [self] in networkReader.resetToday() } }

    // MARK: Derived values

    var topByCPU: [ProcessUsage] { Array(processes.sorted { $0.cpu > $1.cpu }.prefix(config.topProcesses)) }
    var topByMemory: [ProcessUsage] { Array(processes.sorted { $0.memory > $1.memory }.prefix(config.topProcesses)) }
    func sensors(_ kind: SensorKind) -> [SensorReading] { sensors.filter { $0.kind == kind } }
    var hottest: Double? { cpu.temperature ?? sensors(.temperature).map(\.value).max() }

    /// The value 0…1 a module's widgets show by default.
    func fraction(_ m: Module) -> Double {
        switch m {
        case .cpu: cpu.total
        case .gpu: gpu.utilization
        case .memory: memory.usedFraction
        case .disk: disk.mainUsedFraction
        case .battery: battery.percent
        case .sensors: min(1, (hottest ?? 0) / 100)
        default: 0
        }
    }

    // MARK: Alerts

    private func value(for metric: AlertMetric) -> Double? {
        switch metric {
        case .cpu: cpu.total * 100
        case .gpu: gpu.utilization * 100
        case .memory: memory.usedFraction * 100
        case .disk: disk.mainUsedFraction * 100
        case .temperature: cpu.temperature
        case .batteryLow: battery.present && !battery.pluggedIn ? battery.percent * 100 : nil
        case .download: network.down / 1_000_000
        case .upload: network.up / 1_000_000
        }
    }

    private func checkAlerts() {
        let now = Date()
        for rule in config.alerts where rule.enabled {
            guard let v = value(for: rule.metric) else { alertSince[rule.id] = nil; continue }
            let crossed = rule.metric.fallingEdge ? v <= rule.threshold : v >= rule.threshold
            if !crossed {
                alertSince[rule.id] = nil
                alertFired.remove(rule.id)
                continue
            }
            let since = alertSince[rule.id] ?? now
            alertSince[rule.id] = since
            if !alertFired.contains(rule.id), now.timeIntervalSince(since) >= Double(rule.seconds) {
                alertFired.insert(rule.id)
                notify(rule, value: v)
            }
        }
    }

    private func notify(_ rule: AlertRule, value: Double) {
        let content = UNMutableNotificationContent()
        content.title = rule.metric.fallingEdge ? "Battery is low" : "\(rule.metric.title) is high"
        content.body = "\(rule.metric.title) is \(Format.number(value)) \(rule.metric.unit) (limit \(Format.number(rule.threshold)) \(rule.metric.unit))."
        let request = UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Formatting

enum Format {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func number(_ v: Double) -> String {
        v >= 100 || v == v.rounded() ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
    }

    static func bytes(_ b: Double, decimals: Bool = true) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return (v >= 100 || !decimals ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }

    static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }

    /// RAM in binary units, the way macOS reports it: 32 GB, not 34.4.
    static func memory(_ b: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(Int(v)) B" }
        return (v >= 100 || v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }
    static func bytes(_ b: Int64) -> String { bytes(Double(b)) }

    static func rate(_ bps: Double) -> String { bytes(bps) + "/s" }

    /// Compact rate for the menu bar: "2.4M", "312K".
    static func shortRate(_ bps: Double) -> String {
        let units = ["B", "K", "M", "G"]
        var v = bps, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return (v >= 10 || i == 0 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + units[i]
    }

    @MainActor static func temperature(_ c: Double?, unit: Bool = false) -> String {
        guard let c else { return "—" }
        let f = Monitor.shared.config.temperatureUnit == .fahrenheit
        return "\(Int((f ? c * 9 / 5 + 32 : c).rounded()))" + (unit ? (f ? " °F" : " °C") : "°")
    }

    static func frequency(_ mhz: Double?) -> String {
        guard let mhz else { return "—" }
        return mhz >= 1000 ? String(format: "%.1f GHz", mhz / 1000) : "\(Int(mhz)) MHz"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        return d > 0 ? "\(d) d \(h) h \(m) m" : h > 0 ? "\(h) h \(m) m" : "\(m) m"
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600
        return d > 0 ? "\(d) d \(h) h" : "\(h) h \((s % 3600) / 60) m"
    }

    static func minutes(_ m: Int?) -> String {
        guard let m else { return "—" }
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }
}
