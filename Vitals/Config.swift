import Foundation
import SwiftUI

/// The nine things Vitals watches. Order is the order they appear in the panel.
enum Module: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, battery, sensors, bluetooth, clock
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disks"
        case .network: "Network"
        case .battery: "Battery"
        case .sensors: "Sensors & Fans"
        case .bluetooth: "Bluetooth"
        case .clock: "Clock"
        }
    }

    /// Short tag drawn in Mini and Label widgets.
    var tag: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .disk: "SSD"
        case .network: "NET"
        case .battery: "BAT"
        case .sensors: "TMP"
        case .bluetooth: "BT"
        case .clock: "TIME"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .sensors: "thermometer.medium"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .clock: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .purple
        case .memory: .green
        case .disk: .orange
        case .network: .cyan
        case .battery: Color(red: 0.19, green: 0.63, blue: 0.31)
        case .sensors: .pink
        case .bluetooth: .indigo
        case .clock: .gray
        }
    }

    /// Widget styles that make sense for this module's data.
    var styles: [WidgetStyle] {
        switch self {
        case .cpu, .gpu: [.mini, .lineChart, .barChart, .pieChart, .tachometer, .label, .dot, .text]
        case .memory: [.mini, .memory, .lineChart, .pieChart, .tachometer, .label, .dot, .text]
        case .disk: [.mini, .barChart, .pieChart, .speed, .label, .dot, .text]
        case .network: [.speed, .networkChart, .label, .dot, .text]
        case .battery: [.battery, .mini, .label, .dot, .text]
        case .sensors: [.stack, .mini, .label, .text]
        case .bluetooth: [.stack, .label, .text]
        case .clock: [.text]
        }
    }

    var defaultStyle: WidgetStyle {
        switch self {
        case .cpu: .lineChart
        case .gpu: .mini
        case .memory: .memory
        case .disk: .barChart
        case .network: .speed
        case .battery: .battery
        case .sensors: .stack
        case .bluetooth: .label
        case .clock: .text
        }
    }
}

/// The 13 menu-bar widget styles.
enum WidgetStyle: String, Codable, CaseIterable, Identifiable {
    case mini, lineChart, barChart, pieChart, networkChart, speed, label, tachometer, memory, battery, stack, dot, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mini: "Mini"
        case .lineChart: "Line chart"
        case .barChart: "Bar chart"
        case .pieChart: "Pie chart"
        case .networkChart: "Network chart"
        case .speed: "Speed"
        case .label: "Label"
        case .tachometer: "Tachometer"
        case .memory: "Memory"
        case .battery: "Battery"
        case .stack: "Stack"
        case .dot: "Dot"
        case .text: "Text"
        }
    }
}

enum WidgetColor: String, Codable, CaseIterable {
    case byValue, accent, monochrome
    var title: String {
        switch self {
        case .byValue: "By utilization"
        case .accent: "Accent color"
        case .monochrome: "Monochrome"
        }
    }
}

struct WidgetConfig: Codable, Equatable {
    var enabled = true
    var style: WidgetStyle
    var color: WidgetColor = .byValue
    var showLabel = true
    var ownItem = false
    /// Template for the Text style: $cpu, $gpu, $mem, $disk, $down, $up, $bat, $temp, $fan, $time.
    var template = ""
}

enum TemperatureUnit: String, Codable, CaseIterable {
    case celsius, fahrenheit
    var title: String { self == .celsius ? "°C" : "°F" }
}

enum AlertMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, temperature, batteryLow, download, upload
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU usage"
        case .gpu: "GPU usage"
        case .memory: "Memory used"
        case .disk: "Disk used"
        case .temperature: "CPU temperature"
        case .batteryLow: "Battery below"
        case .download: "Download speed"
        case .upload: "Upload speed"
        }
    }
    var unit: String {
        switch self {
        case .temperature: "°C"
        case .download, .upload: "MB/s"
        default: "%"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .temperature: 40...110
        case .download, .upload: 1...500
        default: 5...100
        }
    }
    /// Battery fires when the value goes *below* the limit; everything else fires above.
    var fallingEdge: Bool { self == .batteryLow }
}

struct AlertRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var metric: AlertMetric
    var threshold: Double
    var seconds: Int = 10
    var enabled = true
}

struct ClockZone: Codable, Equatable, Identifiable {
    var id = UUID()
    var identifier: String
    var label: String
}

struct Config: Codable, Equatable {
    var combined = true
    var interval: Double = 1
    var temperatureUnit: TemperatureUnit = .celsius
    var topProcesses = 5
    var lookUpPublicIP = true
    var enabled: [Module: Bool] = Dictionary(uniqueKeysWithValues: Module.allCases.map { ($0, $0 != .bluetooth && $0 != .clock) })
    var widgets: [Module: WidgetConfig] = Dictionary(uniqueKeysWithValues: Module.allCases.map {
        // A compact default: macOS already shows the battery and clock.
        ($0, WidgetConfig(enabled: [.cpu, .memory, .network, .sensors].contains($0), style: $0.defaultStyle))
    })
    var order: [Module] = Module.allCases
    var starredSensors: [String] = ["CPU performance cores"]
    var alerts: [AlertRule] = [
        AlertRule(metric: .cpu, threshold: 90, seconds: 30),
        AlertRule(metric: .temperature, threshold: 95, seconds: 10),
        AlertRule(metric: .batteryLow, threshold: 15, seconds: 1)
    ]
    var clocks: [ClockZone] = [ClockZone(identifier: TimeZone.current.identifier, label: "Local"),
                               ClockZone(identifier: "Europe/London", label: "London")]
    var clockFormat = "EEE d MMM  HH:mm"
    var hotKeyEnabled = true

    func isOn(_ m: Module) -> Bool { enabled[m] ?? true }
    func widget(_ m: Module) -> WidgetConfig { widgets[m] ?? WidgetConfig(style: m.defaultStyle) }

    // Tolerant decoding: keys added in later versions fall back to defaults.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        combined = (try? c.decode(Bool.self, forKey: .combined)) ?? d.combined
        interval = (try? c.decode(Double.self, forKey: .interval)) ?? d.interval
        temperatureUnit = (try? c.decode(TemperatureUnit.self, forKey: .temperatureUnit)) ?? d.temperatureUnit
        topProcesses = (try? c.decode(Int.self, forKey: .topProcesses)) ?? d.topProcesses
        lookUpPublicIP = (try? c.decode(Bool.self, forKey: .lookUpPublicIP)) ?? d.lookUpPublicIP
        enabled = d.enabled.merging((try? c.decode([Module: Bool].self, forKey: .enabled)) ?? [:]) { $1 }
        widgets = d.widgets.merging((try? c.decode([Module: WidgetConfig].self, forKey: .widgets)) ?? [:]) { $1 }
        let savedOrder = (try? c.decode([Module].self, forKey: .order)) ?? d.order
        order = savedOrder + Module.allCases.filter { !savedOrder.contains($0) }
        starredSensors = (try? c.decode([String].self, forKey: .starredSensors)) ?? d.starredSensors
        alerts = (try? c.decode([AlertRule].self, forKey: .alerts)) ?? d.alerts
        clocks = (try? c.decode([ClockZone].self, forKey: .clocks)) ?? d.clocks
        clockFormat = (try? c.decode(String.self, forKey: .clockFormat)) ?? d.clockFormat
        hotKeyEnabled = (try? c.decode(Bool.self, forKey: .hotKeyEnabled)) ?? d.hotKeyEnabled
    }

    private static let key = "config.v1"

    static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
