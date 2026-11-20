import Foundation

enum PowerSource: String, CaseIterable, Sendable {
    case bluetooth, gx, demo
    var title: String {
        switch self {
        case .bluetooth: "Victron Bluetooth"
        case .gx: "Victron GX (LAN)"
        case .demo: "Demo"
        }
    }
}

struct ConnectionSettings: Equatable, Sendable {
    var mode: PowerSource = .bluetooth
    var demo: Bool { mode == .demo }
    var host = ""
    var port: UInt16 = 502
    static let refreshRange = 2...30
    var refresh = 5

    static func cleanHost(_ input: String) -> String? {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let ipv6 = host.filter { $0 == ":" }.count >= 2
        guard !host.isEmpty, host.utf8.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0) || (ipv6 && ":%".contains($0))) }) else { return nil }
        return host
    }
}

struct MenuDisplay: Equatable {
    var solar = true
    var ac = true
    var battery = true
    var batteryPower = false

    var hasGraph: Bool { solar || ac || battery || batteryPower }

    static func load(from defaults: UserDefaults) -> Self {
        Self(solar: defaults.object(forKey: "menu.solar") as? Bool ?? true,
             ac: defaults.object(forKey: "menu.ac") as? Bool ?? true,
             battery: defaults.object(forKey: "menu.battery") as? Bool ?? true,
             batteryPower: defaults.object(forKey: "menu.batteryPower") as? Bool ?? false)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(solar, forKey: "menu.solar")
        defaults.set(ac, forKey: "menu.ac")
        defaults.set(battery, forKey: "menu.battery")
        defaults.set(batteryPower, forKey: "menu.batteryPower")
    }
}

enum InputSource: UInt16, Codable, Sendable {
    case unknown = 0, grid = 1, generator = 2, shore = 3, disconnected = 240

    var title: String {
        switch self {
        case .unknown: "AC input"
        case .grid: "Grid input"
        case .generator: "Generator"
        case .shore: "Shore power"
        case .disconnected: "AC input"
        }
    }
}

struct Telemetry: Codable, Sendable {
    var soc: Double?
    var voltage: Double?
    var current: Double?
    var batteryPower: Double?
    var solar: Double?
    var load: Double?
    var apparentLoad: Double?
    var acOutputVoltage: Double?
    var acVoltageDisplay: String? { acOutputVoltage.map { String(format: "%.1f V AC", $0) } }
    var acDisplay: String { if let load { watts(load) } else { voltAmps(apparentLoad) } }
    var dcLoad: Double?
    var source: InputSource?
    var inputPower: Double?

    init(soc: Double? = nil, voltage: Double? = nil, current: Double? = nil, batteryPower: Double? = nil,
         solar: Double? = nil, load: Double? = nil, apparentLoad: Double? = nil, acOutputVoltage: Double? = nil, dcLoad: Double? = nil, source: InputSource? = nil, inputPower: Double? = nil) {
        self.soc = soc; self.voltage = voltage; self.current = current; self.batteryPower = batteryPower
        self.solar = solar; self.load = load; self.apparentLoad = apparentLoad; self.acOutputVoltage = acOutputVoltage; self.dcLoad = dcLoad; self.source = source; self.inputPower = inputPower
    }

    init(registers: [UInt16: UInt16]) {
        func unsigned(_ address: UInt16) -> Double? {
            guard let value = registers[address], value != .max else { return nil }
            return Double(value)
        }
        func signed(_ address: UInt16) -> Double? {
            guard let value = registers[address], value != 0x7FFF else { return nil }
            return Double(Int16(bitPattern: value))
        }
        func total(_ values: [Double?]) -> Double? {
            let reported = values.compactMap { $0 }
            return reported.isEmpty ? nil : reported.reduce(0, +)
        }
        let charge = unsigned(843)
        soc = charge.flatMap { $0 <= 100 ? $0 : nil }
        voltage = unsigned(840).map { $0 / 10 }
        current = signed(841).map { $0 / 10 }
        batteryPower = signed(842)
        solar = total([unsigned(850)] + (808...816).map { unsigned($0) })
        load = total((817...819).map { unsigned($0) })
        dcLoad = signed(860)
        source = registers[826].flatMap(InputSource.init(rawValue:))
        switch source {
        case .generator: inputPower = total((823...825).map { signed($0) })
        case .grid, .shore: inputPower = total((820...822).map { signed($0) })
        default: inputPower = nil
        }
    }

    var hasData: Bool {
        [soc, voltage, current, batteryPower, solar, load, apparentLoad, acOutputVoltage, dcLoad, inputPower].contains { $0 != nil }
    }

    static func demo(at date: Date) -> Self {
        let t = date.timeIntervalSinceReferenceDate
        let solar = 760 + 360 * sin(t / 79) + 120 * sin(t / 17)
        let load = 460 + 125 * sin(t / 33) + 85 * sin(t / 11)
        let dc = 76 + 16 * sin(t / 25)
        let power = solar - load - dc
        return Self(registers: [
            826: 240, 840: UInt16(533 + 4 * sin(t / 42)),
            841: UInt16(bitPattern: Int16(power / 5.33)), 842: UInt16(bitPattern: Int16(power)),
            843: UInt16(76 + 5 * sin(t / 255)), 850: UInt16(solar), 817: UInt16(load),
            860: UInt16(dc)
        ])
    }
}

struct Reading: Codable, Sendable {
    let date: Date
    let value: Telemetry?
    var refresh: Int? = nil
    var measuredAt: Date? = nil
}

struct DashboardHistory {
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func retain(_ readings: [Reading], at now: Date) -> [Reading] {
        let first = readings.firstIndex { now.timeIntervalSince($0.date) <= maxAge } ?? readings.endIndex
        return first == 0 ? readings : Array(readings[first...])
    }

    static func window(_ readings: [Reading], at now: Date) -> TimeInterval {
        // Use the same actual time domain for every dashboard graph, including during startup.
        max(1, now.timeIntervalSince(readings.first(where: { $0.value?.hasData == true })?.date ?? now))
    }

    static func startLabel(_ window: TimeInterval) -> String {
        let seconds = Int(window.rounded(.down))
        if seconds < 60 { return "\(seconds) SEC AGO" }
        if seconds < 3600 { return "\(seconds / 60) MIN AGO" }
        let minutes = (seconds / 60) % 60
        return minutes == 0 ? "\(seconds / 3600) HR AGO" : "\(seconds / 3600)H \(minutes)M AGO"
    }
}

// Reuse the same timeline rules in the status item and dashboard.
struct Timeline {
    static func segments(_ readings: [Reading], metric: KeyPath<Telemetry, Double?>,
                         ending end: Date, window: TimeInterval, maxGap: TimeInterval) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var segment: [CGPoint] = []
        var previous: Reading?
        for reading in readings {
            let age = end.timeIntervalSince(reading.date)
            guard age >= 0, age <= window else { continue }
            if reading.value?[keyPath: metric] == nil || previous.map({ earlier in
                let interval = max(earlier.refresh ?? 0, reading.refresh ?? 0)
                let gap = interval > 0 ? Double(interval) * 1.8 + 4 : maxGap
                return reading.date.timeIntervalSince(earlier.date) > gap
            }) == true {
                if !segment.isEmpty { result.append(segment); segment = [] }
            }
            if let value = reading.value?[keyPath: metric] {
                segment.append(CGPoint(x: 1 - age / window, y: value))
            }
            previous = reading
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }

    static func powerCeiling(_ readings: [Reading], solar: Bool = true, ac: Bool = true) -> Double {
        let peak = readings.reduce(0.0) { peak, reading in
            max(peak, solar ? (reading.value?.solar ?? 0) : 0, ac ? (reading.value?.load ?? 0) : 0)
        }
        return chartCeiling(peak: peak)
    }

    static func apparentCeiling(_ readings: [Reading]) -> Double {
        chartCeiling(peak: readings.reduce(0) { max($0, $1.value?.apparentLoad ?? 0) })
    }

    static func batteryPowerRange(_ readings: [Reading]) -> ClosedRange<Double> {
        let peak = readings.reduce(0.0) { max($0, abs($1.value?.batteryPower ?? 0)) }
        let limit = max(10, chartCeiling(peak: peak, minimum: 10))
        return -limit...limit
    }

    static func batteryVoltageRange(_ readings: [Reading]) -> ClosedRange<Double> {
        let values = readings.compactMap { $0.value?.voltage }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        // A 0.5 V minimum span keeps a steady battery visible without exaggerating small fluctuations.
        let span = max(0.5, (high - low) * 1.2)
        let center = (low + high) / 2
        return (floor((center - span / 2) * 10) / 10)...(ceil((center + span / 2) * 10) / 10)
    }

    private static func chartCeiling(peak: Double, minimum: Double = 500) -> Double {
        let step = pow(10, floor(log10(max(minimum, peak * 1.12)))) / 2
        return max(minimum, ceil(peak * 1.12 / step) * step)
    }
}

func watts(_ amount: Double?) -> String {
    guard let amount else { return "—" }
    return abs(amount) >= 1000 ? String(format: "%.2f kW", amount / 1000) : String(format: "%.0f W", amount)
}

func signedWatts(_ amount: Double?) -> String {
    guard let amount else { return "—" }
    return (amount > 0 ? "+" : "") + watts(amount)
}

func voltAmps(_ amount: Double?) -> String {
    guard let amount else { return "—" }
    return abs(amount) >= 1000 ? String(format: "%.2f kVA", amount / 1000) : String(format: "%.0f VA", amount)
}
