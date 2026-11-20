import CommonCrypto
import Foundation

struct InstantReadout {
    enum Kind: UInt8 {
        case solar = 1, monitor, inverter, dcConverter, lithium, inverterRS, gx, charger, protect, bms, multiRS, veBus, dcMeter
        case orionXS = 15, batterySense = 254

        var title: String {
            switch self {
            case .solar: "Solar charger"
            case .monitor: "Battery monitor"
            case .inverter: "Inverter"
            case .dcConverter: "DC–DC charger"
            case .lithium: "Lithium battery"
            case .inverterRS: "Inverter RS"
            case .gx: "GX device"
            case .charger: "AC charger"
            case .protect: "BatteryProtect"
            case .bms: "Lynx Smart BMS"
            case .multiRS: "Multi RS"
            case .veBus: "VE.Bus inverter/charger"
            case .dcMeter: "DC energy meter"
            case .orionXS: "Orion XS"
            case .batterySense: "Smart Battery Sense"
            }
        }

        var supported: Bool { self != .gx }
        var batteryPriority: Int? {
            switch self {
            case .monitor: 0
            case .bms: 1
            case .veBus: 2
            case .multiRS, .inverterRS: 3
            default: nil
            }
        }
    }

    struct Values: Equatable {
        var soc: Double?
        var voltage: Double?
        var current: Double?
        var solar: Double?
        var yield: Double?
        var acOut: Double?
        var acIn: Double?
        var acInput: Int?
        var apparent: Double?
        var acVoltage: Double?
        var acCurrent: Double?
        var inputVoltage: Double?
        var inputCurrent: Double?
        var temperature: Double?
        var timeToGo: Double?
        var state: Int?
        var batteryPower: Double? { if let voltage, let current { voltage * current } else { nil } }
        var hasValues: Bool { self != Values() }
    }

    enum Failure: Error { case wrongKey, unsupported, invalid }

    let model: UInt16
    let record: UInt8
    let keyHint: UInt8
    let kind: Kind?
    private let nonce: [UInt8]
    private let payload: [UInt8]

    init?(_ manufacturerData: Data) {
        let bytes = Array(manufacturerData)
        // CoreBluetooth includes the little-endian Bluetooth SIG company identifier (0x02E1).
        guard bytes.count >= 11, bytes[0] == 0xE1, bytes[1] == 0x02, bytes[2] == 0x10 else { return nil }
        model = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        record = bytes[6]
        nonce = Array(bytes[7...8])
        keyHint = bytes[9]
        payload = Array(bytes.dropFirst(10))
        kind = [0xA3A4, 0xA3A5].contains(model) ? .batterySense : Kind(rawValue: record)
    }

    static func key(_ text: String) -> [UInt8]? {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).utf8
        guard hex.count == 32 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        let digits = hex.compactMap(nibble)
        guard digits.count == 32 else { return nil }
        return stride(from: 0, to: 32, by: 2).map { (digits[$0] << 4) | digits[$0 + 1] }
    }

    func decode(key: [UInt8]) throws -> Values {
        guard let kind, kind.supported else { throw Failure.unsupported }
        guard key.count == 16, key.first == keyHint else { throw Failure.wrongKey }
        // Victron AES-CTR: two nonce bytes in wire order, then a big-endian counter at zero.
        var counter = nonce + Array(repeating: UInt8(0), count: 14)
        var clear: [UInt8] = []
        for start in stride(from: 0, to: payload.count, by: 16) {
            var block = [UInt8](repeating: 0, count: 16)
            let capacity = block.count
            var written = 0
            let result = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                                 key, key.count, nil, counter, counter.count, &block, capacity, &written)
            guard result == kCCSuccess, written == 16 else { throw Failure.invalid }
            for i in 0..<min(16, payload.count - start) { clear.append(payload[start + i] ^ block[i]) }
            for i in (2..<16).reversed() { counter[i] &+= 1; if counter[i] != 0 { break } }
        }
        return Self.fields(kind, clear)
    }

    static func fields(_ kind: Kind, _ bytes: [UInt8]) -> Values {
        // Offsets are relative to the decrypted data, after the four-byte record header.
        func number(_ bit: Int, _ count: Int, _ na: Int, _ signed: Bool = false, _ divisor: Double = 1) -> Double? {
            guard bit + count <= bytes.count * 8 else { return nil }
            var n = 0
            for i in 0..<count { n |= Int((bytes[(bit + i) / 8] >> ((bit + i) % 8)) & 1) << i }
            guard n != na else { return nil }
            if signed && n & (1 << (count - 1)) != 0 { n -= 1 << count }
            return Double(n) / divisor
        }
        func u(_ b: Int, _ n: Int, _ div: Double = 1) -> Double? { number(b, n, (1 << n) - 1, false, div) }
        func s16(_ b: Int, _ div: Double = 1) -> Double? { number(b, 16, 0x7FFF, true, div) }
        func temp(_ b: Int) -> Double? { u(b, 7).map { $0 - 40 } }
        var v = Values()
        switch kind {
        case .solar, .inverterRS:
            v.state = u(0, 8).map(Int.init)
            v.voltage = s16(16, 100); v.current = s16(32, 10)
            v.solar = u(kind == .solar ? 64 : 48, 16)
            v.yield = u(kind == .solar ? 48 : 64, 16, 100)
            if kind == .inverterRS { v.acOut = s16(80) }
        case .monitor, .dcMeter:
            v.voltage = s16(16, 100); v.current = number(66, 22, 0x3FFFFF, true, 1000)
            if u(64, 2) == 2 { v.temperature = u(48, 16, 100).map { $0 - 273.15 } }
            if kind == .monitor { v.soc = u(108, 10, 10); v.timeToGo = u(0, 16) }
        case .bms:
            v.voltage = s16(24, 100); v.current = s16(40, 10); v.soc = u(90, 10, 10)
            v.temperature = temp(120); v.timeToGo = u(8, 16)
        case .multiRS, .veBus:
            v.state = u(0, 8).map(Int.init)
            v.current = s16(16, 10); v.voltage = u(32, 14, 100); v.acInput = u(46, 2).map(Int.init)
            if kind == .multiRS {
                v.acIn = s16(48); v.acOut = s16(64); v.solar = u(80, 16); v.yield = u(96, 16, 100)
            } else {
                v.acIn = number(48, 19, 0x3FFFF, true); v.acOut = number(67, 19, 0x3FFFF, true)
                v.temperature = temp(88); v.soc = u(95, 7)
            }
        case .inverter:
            v.state = u(0, 8).map(Int.init); v.voltage = s16(24, 100); v.apparent = u(40, 16)
            v.acVoltage = u(56, 15, 100); v.acCurrent = u(71, 11, 10)
        case .dcConverter, .orionXS:
            v.state = u(0, 8).map(Int.init)
            if kind == .orionXS {
                v.voltage = u(16, 16, 100); v.current = u(32, 16, 10)
                v.inputVoltage = u(48, 16, 100); v.inputCurrent = u(64, 16, 10)
            } else { v.inputVoltage = u(16, 16, 100); v.voltage = s16(32, 100) }
        case .charger:
            v.state = u(0, 8).map(Int.init)
            v.voltage = u(16, 13, 100); v.current = u(29, 11, 10); v.temperature = temp(88)
        case .lithium:
            v.voltage = u(104, 12, 100); v.temperature = temp(120)
        case .batterySense:
            v.voltage = s16(16, 100); v.temperature = u(48, 16, 100).map { $0 - 273.15 }
        case .protect:
            v.state = u(0, 8).map(Int.init); v.inputVoltage = s16(56, 100); v.voltage = u(72, 16, 100)
        case .gx: break // Published layout is marked provisional; don't guess.
        }
        if let soc = v.soc, soc > 100 { v.soc = nil }
        return v
    }
}
