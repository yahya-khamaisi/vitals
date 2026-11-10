import AppKit
import CoreWLAN
import Darwin
import Foundation
import IOKit
import SystemConfiguration

// MARK: - Disks

struct Volume: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let isInternal: Bool
    let ejectable: Bool
    let format: String
    var media: String?
    var smart: String?
    var id: URL { url }
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct DiskStats {
    var volumes: [Volume] = []
    var readRate = 0.0, writeRate = 0.0       // bytes per second
    var totalRead: UInt64 = 0, totalWrite: UInt64 = 0   // bytes since boot
    var lifetime: (read: UInt64, write: UInt64)?          // bytes over the SSD's life, from NVMe SMART
    var mainUsedFraction: Double { volumes.first?.usedFraction ?? 0 }
}

final class DiskReader {
    private var lastBytes: (read: UInt64, write: UInt64)?
    private var lastTime = Date()
    private var details: [URL: (media: String?, smart: String?)] = [:]
    private var detailsTime = Date.distantPast
    private var lifetime: (read: UInt64, write: UInt64)?
    private var lifetimeTime = Date.distantPast

    func read() -> DiskStats {
        var stats = DiskStats()
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                      .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            stats.volumes.append(Volume(url: url, name: v.volumeName ?? url.lastPathComponent, total: Int64(total), free: free,
                                        isInternal: v.volumeIsInternal ?? false, ejectable: v.volumeIsEjectable ?? false,
                                        format: v.volumeLocalizedFormatDescription ?? ""))
        }
        stats.volumes.sort { ($0.url.path == "/" ? 0 : $0.isInternal ? 1 : 2) < ($1.url.path == "/" ? 0 : $1.isInternal ? 1 : 2) }

        // Model and SMART status change rarely; ask diskutil every few minutes.
        if Date().timeIntervalSince(detailsTime) > 300 || stats.volumes.contains(where: { details[$0.url] == nil }) {
            detailsTime = Date()
            for v in stats.volumes where details[v.url] == nil || v.url.path == "/" {
                guard let out = Sys.run("/usr/sbin/diskutil", ["info", "-plist", v.url.path]),
                      let plist = try? PropertyListSerialization.propertyList(from: Data(out.utf8), format: nil) as? [String: Any] else { continue }
                details[v.url] = (plist["MediaName"] as? String, plist["SMARTStatus"] as? String)
            }
        }
        for i in stats.volumes.indices {
            stats.volumes[i].media = details[stats.volumes[i].url]?.media
            stats.volumes[i].smart = details[stats.volumes[i].url]?.smart
        }

        var read: UInt64 = 0, write: UInt64 = 0
        Sys.services("IOBlockStorageDriver") { entry in
            guard let s = Sys.registry(entry, "Statistics") as? [String: Any] else { return }
            read += (s["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (s["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        stats.totalRead = read
        stats.totalWrite = write
        // The drive's own counters only move in 512 KB steps; once a minute is plenty.
        if Date().timeIntervalSince(lifetimeTime) > 60 {
            lifetimeTime = Date()
            lifetime = NVMeSMART.lifetimeBytes()
        }
        stats.lifetime = lifetime
        let now = Date()
        if let last = lastBytes {
            let dt = max(0.1, now.timeIntervalSince(lastTime))
            stats.readRate = Double(read >= last.read ? read - last.read : 0) / dt
            stats.writeRate = Double(write >= last.write ? write - last.write : 0) / dt
        }
        lastBytes = (read, write)
        lastTime = now
        return stats
    }
}

// MARK: - NVMe SMART

/// Lifetime data read and written, straight from each NVMe drive's SMART log. Works without
/// privileges through the system's NVMeSMARTLib plug-in (internal SSDs; USB enclosures rarely expose it).
enum NVMeSMART {
    /// Layout of IONVMeSMARTInterface from <IOKit/storage/nvme/NVMeSMARTLibExternal.h>, which Swift can't import.
    private struct Interface {
        var reserved: UnsafeMutableRawPointer?
        var queryInterface: @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<LPVOID?>?) -> HRESULT
        var addRef: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var release: @convention(c) (UnsafeMutableRawPointer?) -> ULONG
        var version: UInt16
        var revision: UInt16
        var readData: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
    }

    private static let userClientType = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
                                                                        0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    private static let interfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
                                                                     0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    /// kIOCFPlugInInterfaceID, a C macro Swift doesn't see.
    private static let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                                           0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    static func lifetimeBytes() -> (read: UInt64, write: UInt64)? {
        var read: UInt64 = 0, write: UInt64 = 0, found = false
        Sys.services("IOBlockStorageDevice") { device in
            guard (Sys.registry(device, "NVMe SMART Capable") as? Bool) == true,
                  let units = dataUnits(device) else { return }
            // One data unit is 1,000 blocks of 512 bytes.
            read &+= units.read &* 512_000
            write &+= units.write &* 512_000
            found = true
        }
        return found ? (read, write) : nil
    }

    private static func dataUnits(_ device: io_service_t) -> (read: UInt64, write: UInt64)? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, userClientType, plugInInterfaceID, &plugin, &score) == KERN_SUCCESS,
              let plugin, let vtable = plugin.pointee else { return nil }
        defer { IODestroyPlugInInterface(plugin) }
        var raw: LPVOID?
        guard vtable.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(interfaceID), &raw) == S_OK, let raw else { return nil }
        let smart = raw.assumingMemoryBound(to: UnsafeMutablePointer<Interface>.self).pointee
        defer { _ = smart.pointee.release(raw) }
        let log = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
        defer { log.deallocate() }
        log.initializeMemory(as: UInt8.self, repeating: 0, count: 512)
        guard smart.pointee.readData(raw, log) == kIOReturnSuccess else { return nil }
        // NVMe SMART log: Data Units Read at byte 32, Data Units Written at byte 48 (low 64 bits of 128).
        return (log.loadUnaligned(fromByteOffset: 32, as: UInt64.self), log.loadUnaligned(fromByteOffset: 48, as: UInt64.self))
    }
}

// MARK: - Network

struct NetworkStats {
    var down = 0.0, up = 0.0                   // bytes per second
    var todayDown: UInt64 = 0, todayUp: UInt64 = 0
    var interface = ""
    var kind = "Offline"                        // Wi‑Fi, Ethernet, Offline
    var ssid: String?
    var rssi: Int?
    var linkSpeed: Double?                      // Mbps
    var localIP: String?
    var publicIP: String?
    var router: String?
    var routerLatency: Double?                  // ms
    var internetLatency: Double?
    var dns: [String] = []
    var online: Bool { !interface.isEmpty }
}

struct NetProcess: Identifiable {
    let name: String
    let down: Double
    let up: Double
    var id: String { name }
}

final class NetworkReader {
    private var last: (down: UInt64, up: UInt64, iface: String)?
    private var lastTime = Date()
    private var publicIP: String?
    private var publicIPTime = Date.distantPast
    private var publicIPInterface = ""
    private var latency: (router: Double?, internet: Double?) = (nil, nil)
    private var latencyTime = Date.distantPast
    private let defaults = UserDefaults.standard

    func read(lookUpPublicIP: Bool) -> NetworkStats {
        var stats = NetworkStats()
        let store = SCDynamicStoreCreate(nil, "Vitals" as CFString, nil, nil)
        let ipv4 = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) } as? [String: Any]
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) } as? [String: Any]
        stats.interface = ipv4?["PrimaryInterface"] as? String ?? ""
        stats.router = ipv4?["Router"] as? String
        stats.dns = dns?["ServerAddresses"] as? [String] ?? []

        let wifi = CWWiFiClient.shared().interface()
        if stats.interface.isEmpty {
            stats.kind = "Offline"
        } else if let wifi, wifi.interfaceName == stats.interface {
            stats.kind = "Wi‑Fi"
            stats.ssid = wifi.ssid()
            let rssi = wifi.rssiValue()
            stats.rssi = rssi == 0 ? nil : rssi
            let rate = wifi.transmitRate()
            stats.linkSpeed = rate > 0 ? rate : nil
        } else {
            stats.kind = "Ethernet"
        }

        let (down, up) = Self.counters(stats.interface)
        stats.localIP = Self.address(stats.interface)
        let now = Date()
        if let last, last.iface == stats.interface {
            let dt = max(0.1, now.timeIntervalSince(lastTime))
            let dDown = down >= last.down ? down - last.down : 0
            let dUp = up >= last.up ? up - last.up : 0
            stats.down = Double(dDown) / dt
            stats.up = Double(dUp) / dt
            addToday(dDown, dUp)
        }
        last = (down, up, stats.interface)
        lastTime = now
        let today = todayTotals()
        stats.todayDown = today.down
        stats.todayUp = today.up

        if lookUpPublicIP, stats.online, now.timeIntervalSince(publicIPTime) > 600 || publicIPInterface != stats.interface {
            publicIPTime = now
            publicIPInterface = stats.interface
            fetchPublicIP()
        }
        stats.publicIP = lookUpPublicIP ? publicIP : nil

        if stats.online, now.timeIntervalSince(latencyTime) > 10 {
            latencyTime = now
            let router = stats.router
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let r = router.flatMap(Self.ping)
                let i = Self.ping("1.1.1.1")
                DispatchQueue.main.async { self?.latency = (r, i) }
            }
        }
        stats.routerLatency = stats.online ? latency.router : nil
        stats.internetLatency = stats.online ? latency.internet : nil
        return stats
    }

    func resetToday() {
        defaults.set(0, forKey: "net.today.down")
        defaults.set(0, forKey: "net.today.up")
    }

    private static var dayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func todayTotals() -> (down: UInt64, up: UInt64) {
        if defaults.string(forKey: "net.today.day") != Self.dayKey { return (0, 0) }
        return (UInt64(max(0, defaults.double(forKey: "net.today.down"))), UInt64(max(0, defaults.double(forKey: "net.today.up"))))
    }

    private func addToday(_ down: UInt64, _ up: UInt64) {
        if defaults.string(forKey: "net.today.day") != Self.dayKey {
            defaults.set(Self.dayKey, forKey: "net.today.day")
            resetToday()
        }
        defaults.set(defaults.double(forKey: "net.today.down") + Double(down), forKey: "net.today.down")
        defaults.set(defaults.double(forKey: "net.today.up") + Double(up), forKey: "net.today.up")
    }

    private func fetchPublicIP() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Vitals", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ip.count < 46, !ip.isEmpty else { return }
            DispatchQueue.main.async { self?.publicIP = ip }
        }.resume()
    }

    /// 64-bit byte counters for one interface, from the routing table.
    static func counters(_ name: String) -> (UInt64, UInt64) {
        guard !name.isEmpty else { return (0, 0) }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        let index = if_nametoindex(name)
        var down: UInt64 = 0, up: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(msg.ifm_index) == index {
                        down = msg.ifm_data.ifi_ibytes
                        up = msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
                if header.ifm_msglen == 0 { break }
            }
        }
        return (down, up)
    }

    static func address(_ name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard !name.isEmpty, getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: p.pointee.ifa_name) == name, let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    static func ping(_ host: String) -> Double? {
        guard let out = Sys.run("/sbin/ping", ["-c", "1", "-t", "2", "-q", host], timeout: 3),
              let line = out.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
              let values = line.split(separator: "=").last?.split(separator: "/"), values.count >= 2 else { return nil }
        return Double(values[1].trimmingCharacters(in: .whitespaces))
    }

    /// Bytes per second for each process over one second, from `nettop`.
    static func processes() -> [NetProcess] {
        guard let out = Sys.run("/usr/bin/nettop", ["-P", "-L", "2", "-d", "-s", "1", "-x", "-J", "bytes_in,bytes_out"], timeout: 4) else { return [] }
        let lines = out.split(separator: "\n")
        guard let lastHeader = lines.lastIndex(where: { $0.hasPrefix(",") || $0.contains("bytes_in") }) else { return [] }
        return lines[(lastHeader + 1)...].compactMap { line in
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let down = Double(cols[1]), let up = Double(cols[2]), down + up > 0 else { return nil }
            var name = String(cols[0])
            if let dot = name.lastIndex(of: "."), Int(name[name.index(after: dot)...]) != nil { name = String(name[..<dot]) }
            return NetProcess(name: name, down: down, up: up)
        }
        .sorted { $0.down + $0.up > $1.down + $1.up }
    }
}

// MARK: - Bluetooth

struct BluetoothDevice: Identifiable, Equatable {
    let name: String
    let percent: Int
    let kind: String          // keyboard, mouse, trackpad, headphones, other
    var id: String { name }
    var symbol: String {
        switch kind {
        case "keyboard": "keyboard"
        case "mouse": "computermouse"
        case "trackpad": "rectangle.and.hand.point.up.left"
        case "headphones": "airpodspro"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

final class BluetoothReader {
    private var profiled: [BluetoothDevice] = []
    private var profiledTime = Date.distantPast

    func read() -> [BluetoothDevice] {
        var devices: [BluetoothDevice] = []
        // Magic keyboards, mice and trackpads report straight into the registry.
        Sys.services("AppleDeviceManagementHIDEventService") { entry in
            guard let percent = (Sys.registry(entry, "BatteryPercent") as? NSNumber)?.intValue,
                  let name = Sys.registry(entry, "Product") as? String else { return }
            let lower = name.lowercased()
            let kind = lower.contains("keyboard") ? "keyboard" : lower.contains("mouse") ? "mouse" : lower.contains("trackpad") ? "trackpad" : "other"
            if !devices.contains(where: { $0.name == name }) { devices.append(BluetoothDevice(name: name, percent: percent, kind: kind)) }
        }
        // Headphones and third-party devices only show up in System Profiler; it's slow, so ask rarely.
        if Date().timeIntervalSince(profiledTime) > 120 {
            profiledTime = Date()
            profiled = Self.profile()
        }
        for d in profiled where !devices.contains(where: { $0.name == d.name }) { devices.append(d) }
        return devices
    }

    private static func profile() -> [BluetoothDevice] {
        guard let out = Sys.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 10),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first,
              let connected = root["device_connected"] as? [[String: Any]] else { return [] }
        var result: [BluetoothDevice] = []
        for entry in connected {
            for (name, value) in entry {
                guard let info = value as? [String: Any] else { continue }
                let levels = ["device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelLeft", "device_batteryLevelRight"]
                    .compactMap { (info[$0] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
                guard let level = levels.min() else { continue }
                let minor = (info["device_minorType"] as? String ?? "").lowercased()
                let kind = minor.contains("headphone") || minor.contains("headset") ? "headphones"
                    : minor.contains("keyboard") ? "keyboard" : minor.contains("mouse") ? "mouse" : "other"
                result.append(BluetoothDevice(name: name, percent: level, kind: kind))
            }
        }
        return result
    }
}
