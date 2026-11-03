import Foundation
import IOKit

/// Apple-silicon performance counters from libIOReport: how long each CPU core and the GPU
/// spent in each frequency state, and how much energy each block used.
final class IOReport {
    struct Sample {
        var eFrequency: Double?      // MHz, average over busy time
        var pFrequency: Double?
        var gpuFrequency: Double?
        var cpuWatts: Double?
        var gpuWatts: Double?
        var aneWatts: Double?
    }

    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias StringGetter = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerGetter = @convention(c) (CFDictionary, UnsafeMutablePointer<Int32>?) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamples?
    private var createDelta: CreateDelta?
    private var group: StringGetter?, channel: StringGetter?, unit: StringGetter?
    private var integer: IntegerGetter?
    private var stateCount: StateCount?, stateName: StateName?, residency: StateResidency?

    private var subscription: OpaquePointer?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime = Date()

    private var eTable: [Double] = []
    private var pTable: [Double] = []
    private var gpuTable: [Double] = []

    init() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ name: String) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copy: CopyGroup = sym("IOReportCopyChannelsInGroup"),
              let subscribe: CreateSubscription = sym("IOReportCreateSubscription") else { return }
        createSamples = sym("IOReportCreateSamples")
        createDelta = sym("IOReportCreateSamplesDelta")
        group = sym("IOReportChannelGetGroup")
        channel = sym("IOReportChannelGetChannelName")
        unit = sym("IOReportChannelGetUnitLabel")
        integer = sym("IOReportSimpleGetIntegerValue")
        stateCount = sym("IOReportStateGetCount")
        stateName = sym("IOReportStateGetNameForIndex")
        residency = sym("IOReportStateGetResidency")

        let wanted: [(String, String?)] = [("Energy Model", nil),
                                           ("CPU Stats", "CPU Core Performance States"),
                                           ("GPU Stats", "GPU Performance States")]
        let merged = NSMutableDictionary()
        let list = NSMutableArray()
        for (g, sub) in wanted {
            guard let dict = copy(g as CFString, sub as CFString?, 0, 0, 0)?.takeRetainedValue() as NSDictionary? else { continue }
            if merged.count == 0 { merged.addEntries(from: dict as! [AnyHashable: Any]) }
            if let items = dict["IOReportChannels"] as? [Any] { list.addObjects(from: items) }
        }
        guard list.count > 0 else { return }
        merged["IOReportChannels"] = list
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = subscribe(nil, merged as CFMutableDictionary, &subscribed, 0, nil)
        channels = subscribed?.takeRetainedValue()
        loadFrequencyTables()
    }

    var isAvailable: Bool { subscription != nil }

    /// Frequencies for each performance state, from the power manager's voltage tables.
    private func loadFrequencyTables() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }
                let raw = stride(from: 0, to: data.count - 7, by: 8).map { i in
                    Double(data[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })
                }.filter { $0 > 0 }
                // Older chips list Hz, newer ones kHz.
                let divisor = (raw.max() ?? 0) > 1e8 ? 1e6 : 1e3
                return raw.map { $0 / divisor }
            }
            if eTable.isEmpty { eTable = table("voltage-states1-sram") }
            if pTable.isEmpty { pTable = table("voltage-states5-sram") }
            if gpuTable.isEmpty { gpuTable = table("voltage-states9-sram") }
        }
    }

    func sample() -> Sample? {
        guard let subscription, let channels, let createSamples, let createDelta else { return nil }
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = current; previousTime = now }
        guard let previous, let delta = createDelta(previous, current, nil)?.takeRetainedValue() as NSDictionary?,
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return nil }
        let seconds = max(0.05, now.timeIntervalSince(previousTime))

        var result = Sample()
        var eSum = 0.0, eTime = 0.0, pSum = 0.0, pTime = 0.0, gSum = 0.0, gTime = 0.0
        var cpuEnergy = 0.0, gpuEnergy = 0.0, aneEnergy = 0.0

        for item in items {
            let g = group?(item)?.takeUnretainedValue() as String? ?? ""
            let name = channel?(item)?.takeUnretainedValue() as String? ?? ""
            if g == "Energy Model" {
                let value = Double(integer?(item, nil) ?? 0)
                let label = unit?(item)?.takeUnretainedValue() as String? ?? "mJ"
                let joules = value / (label == "nJ" ? 1e9 : label == "uJ" || label == "µJ" ? 1e6 : 1e3)
                switch name {
                case "CPU Energy": cpuEnergy += joules
                case "GPU Energy", "GPU": gpuEnergy = max(gpuEnergy, joules)
                case "ANE": aneEnergy += joules
                default: break
                }
                continue
            }
            let isE = name.hasPrefix("ECPU"), isP = name.hasPrefix("PCPU"), isGPU = name == "GPUPH"
            guard (isE || isP || isGPU), let stateCount, let residency, let stateName else { continue }
            let table = isE ? eTable : isP ? pTable : gpuTable
            var busyIndex = 0
            for i in 0..<stateCount(item) {
                let state = stateName(item, i)?.takeUnretainedValue() as String? ?? ""
                if state == "IDLE" || state == "OFF" || state == "DOWN" { continue }
                let time = Double(residency(item, i))
                if busyIndex < table.count, time > 0 {
                    if isE { eSum += table[busyIndex] * time; eTime += time }
                    else if isP { pSum += table[busyIndex] * time; pTime += time }
                    else { gSum += table[busyIndex] * time; gTime += time }
                }
                busyIndex += 1
            }
        }
        if eTime > 0 { result.eFrequency = eSum / eTime }
        if pTime > 0 { result.pFrequency = pSum / pTime }
        if gTime > 0 { result.gpuFrequency = gSum / gTime }
        if cpuEnergy > 0 { result.cpuWatts = cpuEnergy / seconds }
        if gpuEnergy > 0 { result.gpuWatts = gpuEnergy / seconds }
        if aneEnergy > 0 { result.aneWatts = aneEnergy / seconds }
        return result
    }
}
