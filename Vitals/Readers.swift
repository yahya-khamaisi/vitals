import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Snapshots

struct CPUStats {
    var name = ""
    var total = 0.0, system = 0.0, user = 0.0, idle = 1.0     // 0 … 1
    var cores: [Double] = []
    var isPerformance: [Bool] = []
    var load = (0.0, 0.0, 0.0)
    var uptime: TimeInterval = 0
    var eFrequency: Double?, pFrequency: Double?            // MHz
    var temperature: Double?
    var watts: Double?
    var pCount: Int { isPerformance.filter { $0 }.count }
    var eCount: Int { isPerformance.count - pCount }
}

struct GPUStats {
    var name = ""
    var cores: Int?
    var utilization = 0.0, renderer = 0.0, tiler = 0.0       // 0 … 1
    var memoryUsed: UInt64 = 0
    var frequency: Double?
    var temperature: Double?
    var watts: Double?
}

struct MemoryStats {
    var total: UInt64 = 0
    var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0, purgeable: UInt64 = 0
    var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var pressureLevel = 1                                    // 1 normal, 2 warning, 4 critical
    var pressure = 0.0                                       // 0 … 1, how hard the system is working to free memory
    var pageIns: UInt64 = 0, pageOuts: UInt64 = 0
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used ? total - used : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    var pressureTitle: String { pressureLevel >= 4 ? "Critical" : pressureLevel >= 2 ? "Warning" : "Normal" }
}

struct BatteryStats {
    var present = false
    var percent = 0.0                                        // 0 … 1
    var charging = false
    var pluggedIn = false
    var minutesRemaining: Int?
    var cycles: Int?
    var designCapacity: Int?, maxCapacity: Int?, currentCapacity: Int?
    var voltage: Double?, amperage: Double?
    var temperature: Double?
    var adapterWatts: Double?
    var lowPowerMode = false
    var health: Double? { guard let d = designCapacity, let m = maxCapacity, d > 0 else { return nil }; return min(1, Double(m) / Double(d)) }
    var drawingWatts: Double? { guard let v = voltage, let a = amperage else { return nil }; return abs(v * a) }
    var condition: String { (health ?? 1) >= 0.8 ? "Normal" : "Service recommended" }
}

struct ProcessUsage: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double         // percent of one core
    let memory: UInt64      // bytes
    var id: Int32 { pid }
}

// MARK: - Helpers

enum Sys {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func registry(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Calls `body` for every service of a class, releasing each afterwards.
    static func services(_ className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let handle = pipe.fileHandleForReading
        while process.isRunning || handle.availableData.count > 0 {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if Date() > deadline { process.terminate(); break }
                usleep(20_000)
                if !process.isRunning { break }
            } else { data.append(chunk) }
        }
        data.append(handle.readDataToEndOfFile())
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - CPU

final class CPUReader {
    private var previous: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private let isPerformance: [Bool]
    private let name: String

    init() {
        name = Sys.string("machdep.cpu.brand_string") ?? "CPU"
        // Each core in the device tree says which cluster it belongs to.
        var types: [(Int, Bool)] = []
        Sys.services("IOPlatformDevice") { entry in
            guard let data = Sys.registry(entry, "cluster-type") as? Data, let byte = data.first,
                  let id = (Sys.registry(entry, "logical-cpu-id") as? NSNumber)?.intValue else { return }
            types.append((id, byte == UInt8(ascii: "P")))
        }
        let count = Sys.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        if types.count == count {
            isPerformance = types.sorted { $0.0 < $1.0 }.map(\.1)
        } else {
            let e = Sys.int("hw.perflevel1.logicalcpu") ?? 0
            isPerformance = (0..<count).map { $0 >= e }
        }
    }

    func read(into stats: inout CPUStats) {
        stats.name = name
        stats.isPerformance = isPerformance
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            current.append((UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        if previous.count == current.count {
            var user = 0.0, system = 0.0, idle = 0.0
            stats.cores = zip(current, previous).map { c, p in
                let u = Double(c.user &- p.user) + Double(c.nice &- p.nice)
                let s = Double(c.system &- p.system)
                let i = Double(c.idle &- p.idle)
                user += u; system += s; idle += i
                let t = u + s + i
                return t > 0 ? (u + s) / t : 0
            }
            let total = user + system + idle
            if total > 0 {
                stats.user = user / total
                stats.system = system / total
                stats.idle = idle / total
                stats.total = stats.user + stats.system
            }
        }
        previous = current

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        stats.load = (loads[0], loads[1], loads[2])

        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            stats.uptime = Date().timeIntervalSince1970 - TimeInterval(boot.tv_sec)
        }
    }
}

// MARK: - GPU

enum GPUReader {
    static func read(into stats: inout GPUStats) {
        var found = false
        Sys.services("IOAccelerator") { entry in
            guard !found, let perf = Sys.registry(entry, "PerformanceStatistics") as? [String: Any] else { return }
            found = true
            func pct(_ k: String) -> Double { Double((perf[k] as? NSNumber)?.intValue ?? 0) / 100 }
            stats.utilization = pct("Device Utilization %")
            stats.renderer = pct("Renderer Utilization %")
            stats.tiler = pct("Tiler Utilization %")
            stats.memoryUsed = (perf["In use system memory"] as? NSNumber)?.uint64Value ?? 0
            if stats.name.isEmpty {
                stats.name = Sys.registry(entry, "model") as? String ?? "GPU"
                stats.cores = (Sys.registry(entry, "gpu-core-count") as? NSNumber)?.intValue
            }
        }
    }
}

// MARK: - Memory

enum MemoryReader {
    static func read() -> MemoryStats {
        var stats = MemoryStats()
        stats.total = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(vm.internal_page_count), purgeable = UInt64(vm.purgeable_count)
            stats.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            stats.wired = UInt64(vm.wire_count) * page
            stats.compressed = UInt64(vm.compressor_page_count) * page
            stats.purgeable = purgeable * page
            stats.cached = (UInt64(vm.external_page_count) + purgeable) * page
            stats.pageIns = vm.pageins
            stats.pageOuts = vm.pageouts
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stats.swapUsed = swap.xsu_used
            stats.swapTotal = swap.xsu_total
        }
        stats.pressureLevel = Sys.int("kern.memorystatus_vm_pressure_level") ?? 1
        if let freeLevel = Sys.int("kern.memorystatus_level") { stats.pressure = max(0, min(1, 1 - Double(freeLevel) / 100)) }
        return stats
    }
}

// MARK: - Battery

enum BatteryReader {
    static func read() -> BatteryStats {
        var stats = BatteryStats()
        stats.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                stats.present = true
                let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
                stats.percent = max > 0 ? Double(current) / Double(max) : 0
                stats.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                stats.pluggedIn = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
                let minutes = (stats.charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
                stats.minutesRemaining = minutes > 0 ? minutes : nil
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func int(_ k: String) -> Int? { (Sys.registry(service, k) as? NSNumber)?.intValue }
            let data = Sys.registry(service, "BatteryData") as? [String: Any]
            stats.cycles = int("CycleCount")
            stats.designCapacity = int("DesignCapacity") ?? (data?["DesignCapacity"] as? NSNumber)?.intValue
            stats.maxCapacity = int("AppleRawMaxCapacity") ?? (data?["AppleRawMaxCapacity"] as? NSNumber)?.intValue
            stats.currentCapacity = int("AppleRawCurrentCapacity") ?? (data?["AppleRawCurrentCapacity"] as? NSNumber)?.intValue
            if let mv = int("Voltage") { stats.voltage = Double(mv) / 1000 }
            if let raw = Sys.registry(service, "Amperage") as? NSNumber {
                stats.amperage = Double(Int64(bitPattern: raw.uint64Value)) / 1000
            }
            if let t = int("Temperature"), t > 0 { stats.temperature = Double(t) / 100 }
        }
        if stats.pluggedIn, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = adapter[kIOPSPowerAdapterWattsKey] as? Int {
            stats.adapterWatts = Double(watts)
        }
        return stats
    }
}

// MARK: - Processes

enum ProcessReader {
    /// Every process with its recent CPU share and resident memory, from `ps`.
    static func read() -> [ProcessUsage] {
        guard let output = Sys.run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm="]) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { return nil }
            return ProcessUsage(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024)
        }
    }
}
