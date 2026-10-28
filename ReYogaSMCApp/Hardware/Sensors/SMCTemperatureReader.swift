import Foundation
import Darwin
import IOKit

final class SMCTemperatureReader {
    struct Reading { let celsius: Double; let key: String; let source: String }
    private var connection: io_connect_t = 0
    private var keys: [String] = []
    private var cpuKeys: [String] = []
    private var cpuProvider = "SMC"
    private var gpuProvider = "SMC"
    private var info: [String: (size: Int, type: String)] = [:]
    private var nextDiscovery = Date.distantPast
    private(set) var reason = "SMC discovery pending"
    private(set) var cpuReason = "SMC discovery pending"
    private func providerExists(_ name: String) -> Bool {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(name))
        if service != 0 { IOObjectRelease(service); return true }
        let resources = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOResources"))
        guard resources != 0 else { return false }
        defer { IOObjectRelease(resources) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(resources, kIOServicePlane, &iterator) == kIOReturnSuccess else { return false }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            let matches = IOObjectConformsTo(child, name)
            IOObjectRelease(child)
            if matches != 0 { return true }
        }
        return false
    }
    static func cpuTemperatureKeys(available: [String], amd: Bool) -> [String] {
        let order = amd ? ["TC0E", "TC0F", "TC0P", "TC0T"] : ["TC0P", "TC0D", "TC0E", "TC0F", "TC0T"]
        return order.filter { available.contains($0) }
    }
    private func uint32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }
    private func write(_ value: UInt32, into data: inout [UInt8], at offset: Int) {
        for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    }
    private func fourCC(_ key: String) -> UInt32 { key.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private func string(_ value: UInt32) -> String {
        String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }, encoding: .ascii) ?? ""
    }
    private func call(key: String = "", command: UInt8, index: UInt32 = 0, size: Int = 0) throws -> [UInt8] {
        guard connection != 0 else { throw SupportError.message("AppleSMC service is unavailable") }
        var input = [UInt8](repeating: 0, count: 80)
        write(fourCC(key), into: &input, at: 0); write(UInt32(size), into: &input, at: 28)
        input[42] = command; write(index, into: &input, at: 44)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count
        let status = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { result in
                IOConnectCallStructMethod(connection, 2, bytes.baseAddress, bytes.count, result.baseAddress, &outputSize)
            }
        }
        guard status == kIOReturnSuccess, outputSize == 80, output[40] == 0 else {
            throw SupportError.message(String(format: localizedMessage("SMC read failed: transport=0x%08x result=%u bytes=%u"), status, output[40], outputSize))
        }
        return output
    }
    private func read(_ key: String) throws -> (String, [UInt8]) {
        if info[key] == nil {
            let result = try call(key: key, command: 9)
            let size = Int(uint32(result, 28))
            guard (1...32).contains(size) else { throw SupportError.message(localizedMessage("Invalid SMC value length for %@", key)) }
            info[key] = (size, string(uint32(result, 32)))
        }
        guard let descriptor = info[key] else { throw SupportError.message("SMC key descriptor unavailable") }
        let result = try call(key: key, command: 5, size: descriptor.size)
        return (descriptor.type, Array(result[48..<(48 + descriptor.size)]))
    }
    static func decodeTemperature(type: String, bytes: [UInt8]) -> Double? {
        guard type == "sp78", bytes.count == 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        let value = Double(raw) / 256
        return value > 0 && value < 150 ? value : nil
    }
    private func discover() throws {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { throw SupportError.message("AppleSMC service is missing") }
            defer { IOObjectRelease(service) }
            let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
            guard status == kIOReturnSuccess else { throw SupportError.message(String(format: localizedMessage("AppleSMC access denied: 0x%08x"), status)) }
        }
        let countData = try read("#KEY").1
        guard countData.count == 4 else { throw SupportError.message("Invalid SMC key count") }
        let count = countData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= 4096 else { throw SupportError.message("SMC key count exceeds discovery limit") }
        keys = []
        var available: [String] = []
        for index in 0..<count {
            let key = string(uint32(try call(command: 8, index: index), 0))
            available.append(key)
            if key.range(of: "^TG[0-9A-F][DP]$", options: .regularExpression) != nil { keys.append(key) }
        }
        keys.sort()

        let amd = providerExists("SMCProcessorAMD")
        cpuProvider = amd ? "SMCProcessorAMD" : "SMC"
        gpuProvider = providerExists("SMCRadeonSensors") ? "SMCRadeonSensors" : "SMC"
        cpuKeys = Self.cpuTemperatureKeys(available: available, amd: amd)
        if Set(keys.filter { $0 != "TGDD" }.map { Array($0)[2] }).count > 1 {
            keys = []
            reason = "Multiple SMC GPUs found; sensor identity needs a reviewed mapping"
        } else { reason = keys.isEmpty ? "No GPU temperature keys published by the SMC plugins" : "GPU temperature keys discovered" }
        cpuReason = cpuKeys.isEmpty ? "No CPU temperature keys published by the SMC plugins" : "CPU temperature keys discovered"
    }
    private enum Sensor { case cpu, gpu }

    private func temperature(_ sensor: Sensor) -> (reading: Reading?, reason: String) {
        do {
            if Date() >= nextDiscovery {
                nextDiscovery = Date().addingTimeInterval(30)
                try discover()
            }
            let selectedKeys: [String]
            let provider: String
            let invalidReason: String
            let discoveryReason: String
            switch sensor {
            case .cpu:
                selectedKeys = cpuKeys; provider = cpuProvider; discoveryReason = cpuReason
                invalidReason = "CPU SMC sensor returned an invalid value or unsupported encoding"
            case .gpu:
                selectedKeys = keys; provider = gpuProvider; discoveryReason = reason
                invalidReason = "GPU SMC sensor returned zero, an invalid value or an unsupported encoding"
            }
            for key in selectedKeys {
                guard let value = try? read(key) else { continue }
                if let temperature = Self.decodeTemperature(type: value.0, bytes: value.1) {
                    return (Reading(celsius: temperature, key: key, source: "\(provider) / \(key)"),
                            localizedMessage("Reading %@ published by %@", key, provider))
                }
            }
            return (nil, selectedKeys.isEmpty ? discoveryReason : invalidReason)
        } catch {
            close(); nextDiscovery = Date().addingTimeInterval(30)
            return (nil, error.localizedDescription)
        }
    }

    func gpuTemperature() -> Reading? {
        let result = temperature(.gpu)
        reason = result.reason
        return result.reading
    }

    func cpuTemperature() -> Reading? {
        let result = temperature(.cpu)
        cpuReason = result.reason
        return result.reading
    }
    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0; keys = []; cpuKeys = []; info = [:]
    }
    deinit { close() }
}
