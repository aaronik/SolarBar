import CoreBluetooth
import Foundation
import Security

struct BluetoothDevice: Identifiable {
    enum Status { case needsKey, waiting, reading, keyMismatch, noReadings, unsupported, keychainUnavailable }
    let id: UUID
    var name: String
    var kind: InstantReadout.Kind?
    var model: UInt16
    var status: Status = .needsKey
    var values: InstantReadout.Values?
    var seen: Date
    var freshReading: Date?

    var typeName: String { kind?.title ?? String(format: "Unknown model 0x%04X", model) }
    func live(at now: Date) -> Bool { freshReading.map { now.timeIntervalSince($0) <= 25 } ?? false }
}

@MainActor
final class BluetoothMonitor: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var devices: [UUID: BluetoothDevice] = [:]
    private var keys: [UUID: [UInt8]] = [:]
    private var keychainFailures: Set<UUID> = []
    private var lastPacket: [UUID: (data: Data, date: Date)] = [:]
    private var active = false
    var issue: String? {
        guard active else { return nil }
        switch central?.state {
        case .poweredOff: return "Bluetooth is off. Turn it on to discover Victron devices."
        case .unauthorized: return "Allow SolarBar under System Settings → Privacy & Security → Bluetooth."
        case .unsupported: return "This Mac does not support Bluetooth Low Energy."
        default: return nil
        }
    }

    func start() {
        guard !active else { return }
        active = true
        if central == nil { central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        if let central { centralManagerDidUpdateState(central) }
    }

    func stop() {
        active = false
        central?.stopScan()
        devices.removeAll()
        keys.removeAll()
        keychainFailures.removeAll()
        lastPacket.removeAll()
    }

    // The central is created on the main queue; callbacks are isolated to the main actor.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active else { return }
        if central.state == .poweredOn {
            if !central.isScanning { central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        } else {
            for id in Array(devices.keys) { devices[id]?.freshReading = nil }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let frame = InstantReadout(data) else { return }
        let id = peripheral.identifier
        let now = Date()
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        if devices[id] == nil {
            if devices.count >= 100 {
                guard let old = devices.values.filter({ keys[$0.id] == nil && now.timeIntervalSince($0.seen) >= 120 })
                    .min(by: { $0.seen < $1.seen }) else { return }
                devices[old.id] = nil
                keychainFailures.remove(old.id)
                lastPacket[old.id] = nil
            }
            devices[id] = BluetoothDevice(id: id, name: name ?? (frame.kind?.title ?? "Victron device"),
                                          kind: frame.kind, model: frame.model, seen: now)
            if frame.kind?.supported == true {
                do { keys[id] = try BLEKeychain.load(id) }
                catch { keychainFailures.insert(id) }
            }
        }
        guard var device = devices[id] else { return }
        device.name = name ?? device.name
        device.seen = now
        device.kind = frame.kind
        device.model = frame.model
        if data != lastPacket[id]?.data {
            lastPacket[id] = (data, now)
            devices[id] = applyFrame(frame, to: device, at: now)
        } else {
            // Identical adverts are often delivered in bursts; don't count a repeated nonce as fresh data.
            devices[id] = device
        }
    }

    private func applyFrame(_ frame: InstantReadout, to original: BluetoothDevice, at now: Date) -> BluetoothDevice {
        var device = original
        device.values = nil
        device.freshReading = nil
        guard frame.kind?.supported == true else { device.status = .unsupported; return device }
        if keychainFailures.contains(device.id) { device.status = .keychainUnavailable; return device }
        guard let key = keys[device.id] else { device.status = .needsKey; return device }
        do {
            let values = try frame.decode(key: key)
            if values.hasValues {
                device.values = values
                device.freshReading = now
                device.status = .reading
            } else { device.status = .noReadings }
        } catch InstantReadout.Failure.wrongKey { device.status = .keyMismatch }
        catch { device.status = .noReadings }
        return device
    }

    func save(_ key: [UInt8], for id: UUID) throws {
        guard let device = devices[id] else { return }
        if let packet = lastPacket[id], let frame = InstantReadout(packet.data), frame.keyHint != key.first {
            throw KeyError.wrongDevice
        }
        try BLEKeychain.save(key, id)
        keys[id] = key
        keychainFailures.remove(id)
        // Decode the recently discovered frame so feedback doesn't depend on the next broadcast.
        if let packet = lastPacket[id], Date().timeIntervalSince(packet.date) <= 25, let frame = InstantReadout(packet.data) {
            devices[id] = applyFrame(frame, to: device, at: packet.date)
        } else {
            devices[id]?.status = .waiting
            devices[id]?.freshReading = nil
            devices[id]?.values = nil
            lastPacket[id] = nil
        }
    }

    func forget(_ id: UUID) throws {
        try BLEKeychain.remove(id)
        keys[id] = nil
        keychainFailures.remove(id)
        devices[id]?.values = nil
        devices[id]?.freshReading = nil
        devices[id]?.status = .needsKey
    }

    func snapshot(at now: Date = Date()) -> [BluetoothDevice] {
        devices.values.filter {
            $0.status != .needsKey || now.timeIntervalSince($0.seen) < 120
        }.sorted {
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    enum KeyError: LocalizedError {
        case wrongDevice
        var errorDescription: String? { "That key does not match this device’s broadcast. Copy its advertisement key again in VictronConnect." }
    }
}

struct BluetoothSummary {
    let telemetry: Telemetry
    let batteryName: String?
    let acName: String?

    init(devices: [BluetoothDevice], at now: Date) {
        let fresh = devices.filter { $0.live(at: now) }
        let batteries = fresh.filter {
            $0.kind?.batteryPriority != nil && ($0.values?.soc != nil || $0.values?.batteryPower != nil)
        }
        let battery = batteries.sorted {
            // Prefer the bank-level monitor over similar readings from an inverter or charger.
            let a = ($0.kind?.batteryPriority ?? 99, $0.values?.soc == nil ? 1 : 0, $0.id.uuidString)
            let b = ($1.kind?.batteryPriority ?? 99, $1.values?.soc == nil ? 1 : 0, $1.id.uuidString)
            return a < b
        }.first
        func outputRank(_ device: BluetoothDevice) -> Int {
            if device.values?.acOut != nil { return 0 }
            if device.values?.apparent != nil { return 1 }
            if device.values?.acVoltage != nil { return 2 }
            return 3
        }
        let ordered = fresh.sorted { $0.id.uuidString < $1.id.uuidString }
        let ac = ordered.filter { outputRank($0) < 3 }.min { outputRank($0) < outputRank($1) }
        let input = ordered.first { $0.id == ac?.id && ($0.values?.acIn != nil || $0.values?.acInput != nil) }
            ?? ordered.first { $0.values?.acIn != nil || $0.values?.acInput != nil }
        let solar = fresh.compactMap { $0.values?.solar }
        batteryName = battery?.name
        acName = ac?.name
        telemetry = Telemetry(soc: battery?.values?.soc, voltage: battery?.values?.voltage,
                              current: battery?.values?.current, batteryPower: battery?.values?.batteryPower,
                              solar: solar.isEmpty ? nil : solar.reduce(0, +), load: ac?.values?.acOut,
                              apparentLoad: ac?.values?.acOut == nil ? ac?.values?.apparent : nil,
                              acOutputVoltage: ac?.values?.acVoltage,
                              source: input?.values?.acInput == 2 ? .disconnected : nil, inputPower: input?.values?.acIn)
    }
}

private enum BLEKeychain {
    private struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)") }
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.aaron.solarbar.instant-readout",
         kSecAttrAccount as String: id.uuidString]
    }

    static func load(_ id: UUID) throws -> [UInt8]? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return (item as? Data).map { Array($0) }
    }

    static func save(_ key: [UInt8], _ id: UUID) throws {
        var item = query(id)
        item[kSecValueData as String] = Data(key)
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: Data(key)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
