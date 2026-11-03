import Foundation
import IOKit

enum SensorKind: String, CaseIterable, Identifiable {
    case temperature, power, voltage, current
    var id: String { rawValue }
    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .power: "Power"
        case .voltage: "Voltage"
        case .current: "Current"
        }
    }
    var unit: String {
        switch self {
        case .temperature: "°"
        case .power: "W"
        case .voltage: "V"
        case .current: "A"
        }
    }
}

struct SensorReading: Identifiable, Equatable {
    let name: String
    let kind: SensorKind
    let value: Double
    var id: String { kind.rawValue + name }
}

struct Fan: Identifiable, Equatable {
    let index: Int
    let name: String
    var rpm: Double
    let min: Double
    let max: Double
    var manual: Bool
    var id: Int { index }
}

/// Temperatures, power, voltage, current and fans, from the SMC and the HID thermal sensors.
final class SensorReader {
    private let smc = SMC.shared
    private let hid = HIDThermal()
    private lazy var keys = Set(smc.allKeys)

    // Groups averaged into one reading. Apple silicon first, then Intel names.
    private let temperatureGroups: [(String, (String) -> Bool)] = [
        ("CPU performance cores", { $0.hasPrefix("Tp") }),
        ("CPU efficiency cores", { $0.hasPrefix("Te") }),
        ("CPU die", { ["TC0D", "TC0E", "TC0F", "TC0P"].contains($0) || ($0.hasPrefix("TC") && $0.hasSuffix("c")) }),
        ("GPU", { $0.hasPrefix("Tg") || ["TG0D", "TG0P"].contains($0) }),
        ("Memory", { $0.hasPrefix("Tm") || $0 == "TM0P" }),
        ("SSD", { $0.hasPrefix("TH") }),
        ("Battery", { $0.hasPrefix("TB") && $0.hasSuffix("T") }),
        ("Wi‑Fi", { $0 == "TW0P" }),
        ("Ambient", { $0 == "TAOL" || $0 == "TA0P" }),
        ("Palm rest", { $0 == "Ts0P" || $0 == "Ts1P" || $0 == "TsOP" })
    ]

    private let named: [(String, SensorKind, String)] = [
        ("PSTR", .power, "System total"),
        ("PPBR", .power, "Battery"),
        ("PDTR", .power, "Power adapter"),
        ("PCPC", .power, "CPU package"),
        ("PCPG", .power, "GPU"),
        ("VP0R", .voltage, "Battery"),
        ("VD0R", .voltage, "Power adapter"),
        ("IPBR", .current, "Battery"),
        ("ID0R", .current, "Power adapter")
    ]

    func readSensors(cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?) -> [SensorReading] {
        var readings: [SensorReading] = []
        let temperatureKeys = keys.filter { $0.hasPrefix("T") }
        var values: [String: Double] = [:]
        for key in temperatureKeys {
            if let v = smc.number(key), v > 5, v < 130 { values[key] = v }
        }
        for (name, match) in temperatureGroups {
            let group = values.filter { match($0.key) }.map(\.value)
            if !group.isEmpty { readings.append(SensorReading(name: name, kind: .temperature, value: group.reduce(0, +) / Double(group.count))) }
        }
        // HID sensors add the SoC die and fill gaps the SMC doesn't cover.
        let thermal = hid.read()
        func average(_ prefix: String) -> Double? {
            let v = thermal.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        func addIfMissing(_ name: String, _ value: Double?) {
            guard let value, !readings.contains(where: { $0.name == name && $0.kind == .temperature }) else { return }
            readings.append(SensorReading(name: name, kind: .temperature, value: value))
        }
        addIfMissing("SoC", average("PMU tdie"))
        addIfMissing("SSD", average("NAND"))
        addIfMissing("Battery", average("gas gauge"))

        for (key, kind, name) in named where keys.contains(key) {
            if let v = smc.number(key), v.isFinite, abs(v) < 500, kind != .power || v > 0.001 {
                readings.append(SensorReading(name: name, kind: kind, value: v))
            }
        }
        if let cpuWatts { readings.append(SensorReading(name: "CPU", kind: .power, value: cpuWatts)) }
        if let gpuWatts { readings.append(SensorReading(name: "GPU", kind: .power, value: gpuWatts)) }
        if let aneWatts, aneWatts > 0.001 { readings.append(SensorReading(name: "Neural Engine", kind: .power, value: aneWatts)) }
        return readings
    }

    /// The SMC names the mode key `F0Md` on most Macs and `F0md` on some newer ones.
    func modeKey(_ index: Int) -> String {
        keys.contains("F\(index)md") ? "F\(index)md" : "F\(index)Md"
    }

    func readFans() -> [Fan] {
        let count = Int(smc.number("FNum") ?? 0)
        return (0..<count).compactMap { i in
            guard let rpm = smc.number("F\(i)Ac") else { return nil }
            let name = count == 1 ? "Fan" : i == 0 ? "Left fan" : i == 1 ? "Right fan" : "Fan \(i + 1)"
            return Fan(index: i, name: name, rpm: max(0, rpm),
                       min: smc.number("F\(i)Mn") ?? 1200, max: smc.number("F\(i)Mx") ?? 6000,
                       manual: (smc.number(modeKey(i)) ?? 0) == 1)
        }
    }
}

/// The thermal sensors IOHIDEventSystem exposes on Apple silicon (die, NAND, battery gauge).
final class HIDThermal {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    private var client: AnyObject?
    private var copyServices: CopyServices?, copyProperty: CopyProperty?, copyEvent: CopyEvent?, floatValue: FloatValue?

    init() {
        guard let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func sym<T>(_ n: String) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: T.self) } }
        guard let create: ClientCreate = sym("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatching = sym("IOHIDEventSystemClientSetMatching") else { return }
        copyServices = sym("IOHIDEventSystemClientCopyServices")
        copyProperty = sym("IOHIDServiceClientCopyProperty")
        copyEvent = sym("IOHIDServiceClientCopyEvent")
        floatValue = sym("IOHIDEventGetFloatValue")
        guard let c = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = setMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        client = c
    }

    /// Sensor name → °C. Names repeat (several gauges), so the last one wins.
    func read() -> [String: Double] {
        guard let client, let copyServices, let copyProperty, let copyEvent, let floatValue,
              let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [:] }
        var result: [String: Double] = [:]
        let temperatureEvent: Int64 = 15
        for service in services {
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = floatValue(event, Int32(temperatureEvent << 16))
            if value > 5, value < 130 { result[name] = value }
        }
        return result
    }
}
