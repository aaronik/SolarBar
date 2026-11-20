import Foundation

@main
struct Smoke {
    static func main() async throws {
        let read = RegisterRead(start: 840, count: 2, id: 258)
        precondition(Array(read.request) == [1, 2, 0, 0, 0, 6, 100, 4, 3, 72, 0, 2])
        let length = try read.bodyLength(Data([1, 2, 0, 0, 0, 7, 100]))
        precondition(length == 6)
        let result = try read.decode(Data([4, 4, 2, 5, 255, 241]))
        precondition(result == [840: 517, 841: 65521])
        for header: [UInt8] in [[0, 2, 0, 0, 0, 7, 100], [1, 2, 0, 0, 0, 7, 0], [1, 2, 0, 0, 255, 255, 100]] {
            do { _ = try read.bodyLength(Data(header)); fatalError("accepted bad header") }
            catch ModbusError.invalidResponse { }
        }
        do { _ = try read.decode(Data([0x84, 2])); fatalError("accepted exception as data") }
        catch ModbusError.exception(2) { }
        do { _ = try read.decode(Data([4, 2, 2, 5, 255, 241])); fatalError("accepted wrong byte count") }
        catch ModbusError.invalidResponse { }

        let sample = Telemetry(registers: [840: 517, 841: 65521, 842: UInt16(bitPattern: -78), 843: 92,
                                           850: 500, 808: 100, 811: 200, 817: 40, 819: 180, 823: 150, 824: 0x7fff, 826: 2])
        precondition(sample.voltage == 51.7 && sample.current == -1.5 && sample.batteryPower == -78 && sample.soc == 92)
        precondition(sample.solar == 800 && sample.load == 220 && sample.inputPower == 150 && sample.source == .generator)
        let empty = Telemetry(registers: [840: .max, 841: 0x7fff, 842: 0x7fff, 843: 110, 850: .max])
        precondition(!empty.hasData)
        let zero = Telemetry(registers: [843: 0, 850: 0, 817: .max, 826: 240])
        precondition(zero.soc == 0 && zero.solar == 0 && zero.load == nil && zero.source == .disconnected)
        precondition(ConnectionSettings.cleanHost(" https://gx.local ") == nil)
        precondition(ConnectionSettings.cleanHost(" [::1] ") == "::1")

        let now = Date()
        let timeline: [Reading] = [(-350, sample), (-120, sample), (-115, sample), (-110, nil), (-105, sample), (0, sample)]
            .map { Reading(date: now.addingTimeInterval($0.0), value: $0.1) }
        let gaps = Timeline.segments(timeline, metric: \.soc, ending: now, window: 300, maxGap: 20)
        precondition(gaps.map(\.count) == [2, 1, 1] && gaps.last?.last?.x == 1)
        precondition(Timeline.powerCeiling(timeline) > 800)
        precondition(Timeline.powerCeiling(timeline, solar: false) == 500)
        precondition(Timeline.powerCeiling(timeline, ac: false) > 800)
        let hourAgo = Reading(date: now.addingTimeInterval(-3600), value: sample, refresh: 30)
        let mixedHistory = [hourAgo, Reading(date: now.addingTimeInterval(-30), value: sample, refresh: 30),
                            Reading(date: now, value: sample, refresh: 2)]
        precondition(DashboardHistory.window(mixedHistory, at: now) == 3600)
        precondition(DashboardHistory.startLabel(3600) == "1 HR AGO")
        precondition(DashboardHistory.retain(mixedHistory, at: now).count == 3)
        precondition(DashboardHistory.retain(mixedHistory, at: now.addingTimeInterval(86401)).isEmpty)
        let tooMany = (0...4000).map { Reading(date: now.addingTimeInterval(Double($0 - 4000)), value: sample) }
        precondition(DashboardHistory.retain(tooMany, at: now).count == DashboardHistory.maxSamples)
        for metric: KeyPath<Telemetry, Double?> in [\.soc, \.batteryPower, \.voltage, \.solar, \.load] {
            let segments = Timeline.segments(mixedHistory, metric: metric, ending: now, window: 3600, maxGap: 8)
            precondition(segments.map(\.count) == [1, 2] && segments.first?.first?.x == 0 && segments.last?.last?.x == 1)
        }
        let suite = "SolarBar.MenuDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(MenuDisplay.load(from: defaults) == MenuDisplay())
        let hidden = MenuDisplay(solar: false, ac: false, battery: false)
        hidden.save(to: defaults)
        precondition(MenuDisplay.load(from: defaults) == hidden)
        precondition(!hidden.hasGraph)
        precondition(MenuDisplay(solar: false).hasGraph && MenuDisplay(ac: false).hasGraph)
        precondition(MenuDisplay(solar: false, ac: false).hasGraph)
        let powerOnly = MenuDisplay(solar: false, ac: false, battery: false, batteryPower: true)
        powerOnly.save(to: defaults)
        precondition(MenuDisplay.load(from: defaults) == powerOnly && powerOnly.hasGraph)
        let powerHistory = [Reading(date: now.addingTimeInterval(-1), value: Telemetry(batteryPower: -310)),
                            Reading(date: now, value: Telemetry(batteryPower: 35))]
        let range = Timeline.batteryPowerRange(powerHistory)
        precondition(range.upperBound > 310 && range.lowerBound == -range.upperBound)
        precondition(Timeline.batteryPowerRange([]) == -10...10)
        precondition(Timeline.segments(powerHistory, metric: \.batteryPower, ending: now, window: 120, maxGap: 10).first?.map(\.y) == [-310, 35])
        let steadyVoltage = Timeline.batteryVoltageRange([Reading(date: now, value: Telemetry(voltage: 12.65))])
        precondition(steadyVoltage.lowerBound < 12.65 && steadyVoltage.upperBound > 12.65)
        precondition(steadyVoltage.upperBound - steadyVoltage.lowerBound >= 0.49)
        let changingVoltage = Timeline.batteryVoltageRange([
            Reading(date: now, value: Telemetry(voltage: 48)), Reading(date: now, value: nil),
            Reading(date: now, value: Telemetry(voltage: 55))])
        precondition(changingVoltage.lowerBound < 48 && changingVoltage.upperBound > 55)
        precondition(Timeline.batteryVoltageRange([]) == 0...1)
        precondition(signedWatts(35) == "+35 W" && signedWatts(-310) == "-310 W")


        try checkBluetooth()

        let args = Array(CommandLine.arguments.dropFirst())
        precondition(args.count == 4)
        func config(_ i: Int) -> ConnectionSettings {
            .init(mode: .gx, host: "127.0.0.1", port: UInt16(args[i])!)
        }
        let remote = try await GXClient.sample(config(0))
        precondition(remote.soc == 84 && remote.solar == 420 && remote.load == 385 && remote.batteryPower == -46)
        precondition(remote.dcLoad == nil && remote.source == .disconnected)
        do { _ = try await GXClient.sample(config(1)); fatalError("accepted bad response") }
        catch ModbusError.invalidResponse { }
        let job = Task { try await GXClient.sample(config(2)) }
        job.cancel()
        do { _ = try await job.value; fatalError("cancel returned data") }
        catch is CancellationError { }
        do { _ = try await GXClient.sample(config(3)); fatalError("silence returned data") }
        catch ModbusError.timeout { }
        print("SolarBar smoke tests passed")
    }
    static func checkBluetooth() throws {
        // Based on public examples from github.com/keshavdv/victron-ble/tree/main/tests,
        // re-encrypted using a synthetic key (not a device credential).
        let testKey = "000102030405060708090a0b0c0d0e0f"
        func packet(_ hex: String) -> Data {
            let digits = Array(hex)
            return Data(stride(from: 0, to: digits.count, by: 2).map {
                UInt8(String(digits[$0...($0 + 1)]), radix: 16)!
            })
        }
        func decode(_ body: String, _ key: String, _ kind: InstantReadout.Kind) throws -> InstantReadout.Values {
            let frame = InstantReadout(packet("e102" + body))!
            precondition(frame.kind == kind)
            return try frame.decode(key: InstantReadout.key(key)!)
        }
        let shunt = try decode("100289a302b04000659dd8e746f48bf054c68ca5751368", testKey, .monitor)
        precondition(shunt.soc == 50 && shunt.voltage == 12.53 && shunt.current == 0 && shunt.timeToGo == nil)
        let solar = try decode("100242a001620700ef399571166713475d96c4ad", testKey, .solar)
        precondition(solar.solar == 19 && solar.yield == 0.03 && solar.voltage == 13.88 && solar.current == 1.4)
        let veBus = try decode("100380270ce1b200b3b47c4b5d78d1c0426a34cba8", testKey, .veBus)
        precondition(veBus.acOut == 45 && veBus.acInput == 2 && veBus.current == -5.9 && veBus.temperature == 30)
        let multi = try decode("100043a40bf4e40076e497a8460dbf50339f191b4e35", testKey, .multiRS)
        precondition(multi.acOut == 722 && multi.solar == 0 && multi.current == -12.8 && multi.yield == 5.32)
        let dc = try decode("1000c0a304121d00472a6f69e455c17c3632", testKey, .dcConverter)
        precondition(dc.inputVoltage == 13.15 && dc.voltage == nil && dc.state == 0)
        let charge = try decode("100030a308f9260017859dd8e1be4e140347614d09", testKey, .charger)
        precondition(charge.voltage == 13.49 && charge.current == 0.4 && charge.temperature == 21)
        let protect = try decode("1080b0a309352300d48ec04106a99d6d8c93a8be903e87", testKey, .protect)
        precondition(protect.voltage == 13.07 && protect.inputVoltage == 13.07 && protect.state == 249)
        precondition(InstantReadout(packet("e102100289a302b040af")) == nil)
        precondition(InstantReadout(packet("ffff100289a302b040af01")) == nil)
        precondition(InstantReadout.fields(.monitor, []).soc == nil)
        precondition(InstantReadout.key(String(repeating: "z", count: 32)) == nil)
        do {
            _ = try decode("100289a302b04000659dd8e746f48bf054c68ca5751368", String(repeating: "f", count: 32), .monitor)
            fatalError("accepted mismatched Bluetooth key")
        } catch InstantReadout.Failure.wrongKey { }

        let now = Date()
        func device(_ name: String, _ kind: InstantReadout.Kind, _ value: InstantReadout.Values, age: TimeInterval = 0) -> BluetoothDevice {
            BluetoothDevice(id: UUID(), name: name, kind: kind, model: 0, status: .reading, values: value,
                            seen: now, freshReading: now.addingTimeInterval(-age))
        }
        // Inverter record: 720 VA, 120.00 V and 6.0 A in packed 15/11-bit fields.
        let inverter = InstantReadout.fields(.inverter, [9, 0, 0, 0x4E, 0x14, 0xD0, 0x02, 0xE0, 0x2E, 0x1E, 0])
        precondition(inverter.apparent == 720 && inverter.acVoltage == 120 && inverter.acCurrent == 6)
        let phoenix = device("Phoenix", .inverter, inverter)
        let onlyApparent = BluetoothSummary(devices: [phoenix], at: now)
        precondition(onlyApparent.acName == "Phoenix" && onlyApparent.telemetry.apparentLoad == 720)
        precondition(onlyApparent.telemetry.load == nil && onlyApparent.telemetry.acDisplay == "720 VA" && onlyApparent.telemetry.hasData)
        let apparentHistory = [Reading(date: now, value: onlyApparent.telemetry)]
        precondition(Timeline.apparentCeiling(apparentHistory) > 720 && Timeline.powerCeiling(apparentHistory) == 500)
        let both = BluetoothSummary(devices: [phoenix, device("MultiPlus", .veBus, veBus)], at: now)
        precondition(both.telemetry.acDisplay == "45 W" && both.telemetry.apparentLoad == nil)
        // Phoenix broadcasts a voltage but uses the protocol's unavailable markers for VA and A.
        let voltageOnly = InstantReadout.fields(.inverter, [9, 0, 0, 0x4E, 0x14, 0xFF, 0xFF, 0xE4, 0xAE, 0xFF, 3])
        precondition(voltageOnly.acVoltage == 120.04 && voltageOnly.apparent == nil && voltageOnly.acCurrent == nil)
        let volts = BluetoothSummary(devices: [device("Phoenix", .inverter, voltageOnly)], at: now)
        precondition(volts.telemetry.hasData && volts.acName == "Phoenix" && volts.telemetry.acVoltageDisplay == "120.0 V AC")
        precondition(volts.telemetry.load == nil && volts.telemetry.apparentLoad == nil)
        let live = [device("Shunt", .monitor, shunt), device("MPPT 1", .solar, solar), device("MPPT 2", .solar, solar),
                    device("MultiPlus", .veBus, veBus), device("Old MPPT", .solar, solar, age: 90)]
        let info = BluetoothSummary(devices: live, at: now)
        precondition(info.batteryName == "Shunt" && info.acName == "MultiPlus")
        precondition(info.telemetry.solar == 38 && info.telemetry.load == 45 && info.telemetry.soc == 50 && info.telemetry.source == .disconnected)
        precondition(!BluetoothSummary(devices: live, at: now.addingTimeInterval(90)).telemetry.hasData)
    }
}
