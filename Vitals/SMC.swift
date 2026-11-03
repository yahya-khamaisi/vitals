import Foundation
import IOKit

/// Reads (and, as root, writes) keys on the System Management Controller through AppleSMC.
/// Reading works for any user; writing fan keys needs the fan helper running as root.
final class SMC {
    static let shared = SMC()

    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
        typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Selector: UInt8 { case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9 }

    struct Value {
        let type: String
        let bytes: [UInt8]

        var number: Double? {
            switch type {
            case "flt ": return bytes.count >= 4 ? Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
            case "ui8 ", "flag": return bytes.first.map(Double.init)
            case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
            case "ui32": return bytes.count >= 4 ? Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
            case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
            case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
            default: return nil
            }
        }
    }

    private var connection: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [UInt32: KeyData.KeyInfo] = [:]

    var isOpen: Bool { connection != 0 }

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
    }

    static func code(_ key: String) -> UInt32 { key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout KeyData) -> Bool {
        guard connection != 0 else { return false }
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        input = output
        return result == kIOReturnSuccess && output.result == 0
    }

    private func info(_ code: UInt32) -> KeyData.KeyInfo? {
        if let cached = infoCache[code] { return cached }
        var input = KeyData()
        input.key = code
        input.data8 = Selector.keyInfo.rawValue
        guard call(&input) else { return nil }
        infoCache[code] = input.keyInfo
        return input.keyInfo
    }

    func read(_ key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        let code = Self.code(key)
        guard let info = info(code) else { return nil }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.read.rawValue
        guard call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: input.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return Value(type: Self.name(info.dataType), bytes: bytes)
    }

    func number(_ key: String) -> Double? { read(key)?.number }

    /// Writes raw bytes. Only succeeds as root.
    @discardableResult
    func write(_ key: String, bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let code = Self.code(key)
        guard let info = info(code) else { return false }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.write.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.prefix(32).enumerated() { raw[i] = b }
        }
        return call(&input)
    }

    /// Writes a number in the key's own encoding.
    @discardableResult
    func write(_ key: String, number: Double) -> Bool {
        guard let current = read(key) else { return false }
        switch current.type {
        case "flt ":
            var f = Float32(number)
            return write(key, bytes: withUnsafeBytes(of: &f) { Array($0) })
        case "ui8 ", "flag":
            return write(key, bytes: [UInt8(max(0, min(255, number)))])
        case "fpe2":
            let v = UInt16(max(0, number) * 4)
            return write(key, bytes: [UInt8(v >> 8), UInt8(v & 0xff)])
        default:
            return false
        }
    }

    /// Every key name on this Mac's SMC.
    lazy var allKeys: [String] = {
        guard let count = number("#KEY") else { return [] }
        lock.lock(); defer { lock.unlock() }
        var keys: [String] = []
        for index in 0..<Int(count) {
            var input = KeyData()
            input.data8 = Selector.keyAtIndex.rawValue
            input.data32 = UInt32(index)
            if call(&input) { keys.append(Self.name(input.key)) }
        }
        return keys
    }()
}
