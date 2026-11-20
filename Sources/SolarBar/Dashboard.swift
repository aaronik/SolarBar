import AppKit
import SwiftUI

private let ink = Color(red: 0.048, green: 0.075, blue: 0.12)
private let surface = Color.white.opacity(0.045)
private let rule = Color.white.opacity(0.10)
private let mint = Color(red: 0.37, green: 0.95, blue: 0.78)
private let voltageCyan = Color(red: 0.38, green: 0.83, blue: 0.98)
private let batteryBlue = Color(nsColor: .systemBlue)
private let sun = Color(red: 1, green: 0.77, blue: 0.37)
private let violet = Color(red: 0.71, green: 0.66, blue: 1)

struct Dashboard: View {
    @ObservedObject var store: MonitorStore
    @State private var showSettings = false
    @State private var editingDevice: UUID?
    @State private var pendingRefresh: Double?
    private var refreshValue: Double { pendingRefresh ?? Double(store.settings.refresh) }
    private var isBLE: Bool { store.settings.mode == .bluetooth }
    private var value: Telemetry? { isBLE ? store.state.history.last?.value : store.state.latest?.value }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(rule)
            ScrollView {
                if showSettings {
                    SettingsForm(settings: store.settings) { settings in
                        store.apply(settings)
                        showSettings = false
                        editingDevice = nil
                    }
                    .padding(18)
                } else {
                    VStack(spacing: 12) {
                        if let issue = store.historyIssue {
                            Text(issue).font(.caption).foregroundStyle(sun)
                        }
                        if let error = store.state.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(sun)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if isBLE && !store.isLive { bluetoothHelp }
                        if !isBLE || store.state.latest?.value?.hasData == true || store.state.history.contains(where: { $0.value?.hasData == true }) {
                            battery
                            batteryCharts
                            power
                            details
                        }
                        menuBarControls
                        refreshControls
                        if isBLE { bluetoothDevices }
                    }
                    .padding(18)
                }
            }
            Divider().overlay(rule)
            footer
        }
        .frame(width: 352)
        .background(ink)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        let live = store.isLive
        let status = store.settings.demo ? "DEMO" : live ? (isBLE ? "BLE LIVE" : "LIVE")
            : store.state.error != nil ? "OFFLINE" : isBLE ? "SCANNING" : "CONNECTING"
        let color = store.settings.demo ? sun : live ? mint : violet
        return HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(mint)
                .frame(width: 34, height: 34)
                .background(mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("SOLARBAR").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(2.3)
                Text(isBLE ? "Victron Bluetooth" : "Off-grid power monitor").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(status).font(.system(size: 9, weight: .bold)).tracking(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var menuBarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            tag("MENU BAR", symbol: "slider.horizontal.3", color: mint)
            HStack(spacing: 7) {
                menuPill("Battery %", isOn: $store.menuDisplay.battery, color: mint)
                menuPill("Battery Power", isOn: $store.menuDisplay.batteryPower, color: batteryBlue)
            }
            HStack(spacing: 7) {
                menuPill("Solar", isOn: $store.menuDisplay.solar, color: sun)
                menuPill(isBLE ? "AC Output" : "AC Load", isOn: $store.menuDisplay.ac, color: violet)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).card()
    }

    private var refreshControls: some View {
        let range = ConnectionSettings.refreshRange
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                tag("REFRESH RATE", symbol: "timer", color: mint)
                Spacer()
                Text("Every \(Int(refreshValue))s")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            Slider(value: Binding(get: { refreshValue }, set: { newValue in
                if pendingRefresh != nil { pendingRefresh = newValue }
                else { store.setRefresh(Int(newValue.rounded())) }
            }), in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                Text("Refresh interval")
            } minimumValueLabel: {
                Text("\(range.lowerBound)s")
            } maximumValueLabel: {
                Text("\(range.upperBound)s")
            } onEditingChanged: { editing in
                if editing { pendingRefresh = refreshValue }
                else if let pendingRefresh {
                    store.setRefresh(Int(pendingRefresh.rounded()))
                    self.pendingRefresh = nil
                }
            }
            .tint(mint)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .accessibilityValue("\(Int(refreshValue)) seconds")
            Text(isBLE ? "Controls how often the app samples incoming Bluetooth broadcasts." : "Controls how often the app updates its readings.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).card()
    }

    private func menuPill(_ title: String, isOn: Binding<Bool>, color: Color) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 5) {
                Circle().fill(color.opacity(isOn.wrappedValue ? 1 : 0.42)).frame(width: 6, height: 6)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(isOn.wrappedValue ? color.opacity(0.16) : surface, in: Capsule())
            .overlay { Capsule().strokeBorder(isOn.wrappedValue ? color.opacity(0.45) : rule) }
            .contentShape(Capsule())
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
        .accessibilityLabel("\(title) in the menu bar")
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .help("Show \(title) in the menu bar")
    }

    private var battery: some View {
        let title = value?.batteryPower.map { $0 > 0 ? "Charging" : $0 < 0 ? "Discharging" : "Idle" } ?? "State of charge"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                tag("BATTERY", symbol: "battery.75percent", color: mint)
                Spacer()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value?.soc.map { $0.rounded() == $0 ? String(format: "%.0f%%", $0) : String(format: "%.1f%%", $0) } ?? "—")
                .font(.system(size: 35, weight: .light, design: .rounded)).monospacedDigit()
                .accessibilityLabel(value?.soc.map { "Battery \(Int($0)) percent" } ?? "Battery charge unavailable")
            if let name = store.state.batteryName {
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            chart(series: [(\.soc, mint)], top: "100%", bottom: "0%", ceil: 100)
                .accessibilityLabel("Battery charge over available history, zero to one hundred percent")
        }.padding(12).card()
    }

    private var batteryCharts: some View {
        let recent = store.state.history
        let powerRange = Timeline.batteryPowerRange(recent)
        let voltageRange = Timeline.batteryVoltageRange(recent)
        return VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    tag("BATTERY POWER", symbol: "bolt.fill", color: batteryBlue)
                    Spacer()
                    Text(signedWatts(value?.batteryPower)).monospacedDigit()
                }
                if recent.contains(where: { $0.value?.batteryPower != nil }) {
                    chart(series: [(\.batteryPower, batteryBlue)], top: signedWatts(powerRange.upperBound),
                          bottom: signedWatts(powerRange.lowerBound), ceil: powerRange.upperBound,
                          floor: powerRange.lowerBound, midpoint: "0 W")
                        .accessibilityLabel("Battery power over available history. Positive is charging; negative is discharging.")
                } else { missingHistory }
            }.padding(12).card()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    tag("BATTERY VOLTAGE", symbol: "waveform.path", color: voltageCyan)
                    Spacer()
                    Text(voltage(value?.voltage)).monospacedDigit()
                }
                if recent.contains(where: { $0.value?.voltage != nil }) {
                    chart(series: [(\.voltage, voltageCyan)], top: voltage(voltageRange.upperBound, digits: 1),
                          bottom: voltage(voltageRange.lowerBound, digits: 1), ceil: voltageRange.upperBound,
                          floor: voltageRange.lowerBound)
                        .accessibilityLabel("Battery voltage over available history, in volts")
                } else { missingHistory }
            }.padding(12).card()
        }
    }

    private var missingHistory: some View {
        Text("No readings yet").font(.caption).foregroundStyle(.secondary)
    }

    private func voltage(_ amount: Double?, digits: Int = 2) -> String {
        amount.map { String(format: "%.*f V", digits, $0) } ?? "—"
    }

    private var power: some View {
        let recent = store.state.history
        let ceiling = Timeline.powerCeiling(recent)
        let showApparent = recent.contains { $0.value?.apparentLoad != nil }
        let showWatts = recent.contains { $0.value?.solar != nil || $0.value?.load != nil }
        let hasACPower = value?.load != nil || value?.apparentLoad != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    tag("SOLAR", symbol: "sun.max.fill", color: sun)
                    Text(watts(value?.solar)).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    tag(isBLE ? "AC OUTPUT" : "AC LOAD", symbol: "house.fill", color: violet)
                    Text(hasACPower ? (value?.acDisplay ?? "—") : (value?.acVoltageDisplay ?? "—"))
                        .font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let name = store.state.acName {
                Text("AC: \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if isBLE && value?.load == nil && value?.apparentLoad == nil {
                Text(value?.acOutputVoltage != nil
                     ? "This inverter broadcasts voltage, but no load power. Voltage alone can’t show how much power you’re using."
                     : "No AC output reading from a nearby inverter with a saved key. Check the inverter’s device card below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showWatts {
                chart(series: [(\.solar, sun), (\.load, violet)], top: watts(ceiling), bottom: "0 W", ceil: ceiling)
                    .accessibilityLabel("Solar production and AC real power over available history")
            }
            if showApparent {
                let apparentCeiling = Timeline.apparentCeiling(recent)
                Text("AC APPARENT POWER").font(.system(size: 9, weight: .semibold)).foregroundStyle(violet)
                    .frame(maxWidth: .infinity, alignment: .leading)
                chart(series: [(\.apparentLoad, violet)], top: voltAmps(apparentCeiling), bottom: "0 VA", ceil: apparentCeiling)
                    .accessibilityLabel("AC apparent power in volt-amps over available history")
            }
        }.padding(12).card()
    }

    private func chart(series: [(KeyPath<Telemetry, Double?>, Color)], top: String, bottom: String, ceil: Double, floor: Double = 0, midpoint: String? = nil) -> some View {
        let axisWidth: CGFloat = midpoint == nil ? 47 : 65
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                VStack(alignment: .trailing) {
                    Text(top)
                    Spacer(minLength: 0)
                    if let midpoint {
                        Text(midpoint)
                        Spacer(minLength: 0)
                    }
                    Text(bottom)
                }.frame(width: axisWidth, alignment: .trailing)
                let lines = series.map { metric, color in
                    (Timeline.segments(store.state.history, metric: metric, ending: store.state.now,
                                       window: store.state.dashboardWindow, maxGap: Double(store.settings.refresh) * 1.8 + 4), color)
                }
                Canvas { context, size in
                    let inset: CGFloat = 3
                    var guides = Path()
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = inset + (size.height - 2 * inset) * fraction
                        guides.move(to: CGPoint(x: inset, y: y))
                        guides.addLine(to: CGPoint(x: size.width - inset, y: y))
                    }
                    context.stroke(guides, with: .color(rule), lineWidth: 1)
                    for (segments, color) in lines {
                        for segment in segments {
                            let points = ChartLine.reduced(segment, columns: max(1, Int(size.width))).map { point in
                                CGPoint(x: inset + (size.width - 2 * inset) * point.x,
                                        y: inset + (size.height - 2 * inset) * (1 - min(1, max(0, (point.y - floor) / (ceil - floor)))))
                            }
                            guard let first = points.first else { continue }
                            if points.count == 1 {
                                context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)), with: .color(color))
                            } else {
                                let path = ChartLine.path(points)
                                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                            }
                        }
                    }
                }
            }.frame(height: 43)
            HStack {
                Text(DashboardHistory.startLabel(store.state.dashboardWindow))
                Spacer()
                Text("NOW")
            }.padding(.leading, axisWidth + 9)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var details: some View {
        VStack(spacing: 6) {
            row("Battery current", value?.current.map { String(format: "%+.1f A", $0) } ?? "—")
            if let dc = value?.dcLoad { row("DC system", watts(dc)) }
            row(value?.source?.title ?? "AC input", value?.source == .disconnected ? "Disconnected" : watts(value?.inputPower))
        }.padding(12).card()
    }

    private func row(_ label: String, _ detail: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(detail).monospacedDigit()
        }.font(.system(size: 11, weight: .medium))
    }

    private func tag(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold)).tracking(0.9).foregroundStyle(color)
    }

    private var bluetoothHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(store.state.devices.isEmpty ? "Looking for Victron devices…" : "Set up your devices", systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold)).foregroundStyle(mint)
            Text("In VictronConnect, open the device’s settings → ⋯ → Product info. Enable Instant Readout if needed, then show Instant Readout Details and copy the Advertisement Key. No PIN or MAC address is needed here.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).card()
    }

    private var bluetoothDevices: some View {
        VStack(alignment: .leading, spacing: 8) {
            tag("NEARBY VICTRON DEVICES", symbol: "antenna.radiowaves.left.and.right", color: mint)
            ForEach(store.state.devices) { device in
                BluetoothDeviceCard(device: device, now: store.state.now, editing: editingDevice == device.id,
                    edit: { editingDevice = editingDevice == device.id ? nil : device.id },
                    save: { key in try store.saveBluetoothKey(key, for: device.id); editingDevice = nil },
                    forget: { try store.forgetBluetoothKey(device.id); editingDevice = nil })
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.settings.demo {
                Text("Simulated readings")
            } else if let sample = store.state.latest {
                Text((store.isLive && isBLE ? "Last broadcast " : store.isLive ? "Updated " : "Last seen ") + (sample.measuredAt ?? sample.date).formatted(date: .omitted, time: .standard))
            } else {
                Text("No readings yet")
            }
            Spacer()
            footerButton(showSettings ? "Back" : "Settings", symbol: showSettings ? "chevron.left" : "gearshape") {
                showSettings.toggle()
            }
            footerButton("Quit", symbol: "power") { NSApplication.shared.terminate(nil) }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.leading, 20).padding(.trailing, 12).padding(.vertical, 10)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title == "Quit" ? "Quit SolarBar" : title)
    }
}

private struct SettingsForm: View {
    @State private var mode: PowerSource
    @State private var host: String
    @State private var port: String
    let refresh: Int
    let apply: (ConnectionSettings) -> Void

    init(settings: ConnectionSettings, apply: @escaping (ConnectionSettings) -> Void) {
        _mode = State(initialValue: settings.mode)
        _host = State(initialValue: settings.host)
        _port = State(initialValue: String(settings.port))
        refresh = settings.refresh
        self.apply = apply
    }

    private var cleanHost: String? { ConnectionSettings.cleanHost(host) }
    private var cleanPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Connection").font(.title3.weight(.semibold))
            Picker("Source", selection: $mode) {
                ForEach(PowerSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if mode == .gx { VStack(alignment: .leading, spacing: 6) {
                Text("GX address").font(.caption)
                TextField("e.g. 192.168.1.50", text: $host).accessibilityLabel("GX address")
                Text("Modbus TCP port").font(.caption)
                TextField("502", text: $port).accessibilityLabel("Modbus TCP port")
            } }
            Text(mode == .gx ? "Enable Modbus TCP in your GX settings, then enter the GX’s local IP address or hostname. Keep port 502 on your local network." : mode == .bluetooth ? "SolarBar listens for Instant Readout broadcasts. Add the per-device advertisement keys on the dashboard." : "Demo shows simulated readings without using Bluetooth or the network.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if mode == .gx && cleanHost == nil && !host.isEmpty {
                Text("Enter a hostname or IP address, without http:// or a port.").font(.caption).foregroundStyle(sun)
            } else if mode == .gx && cleanPort == nil {
                Text("Enter a port from 1 through 65535.").font(.caption).foregroundStyle(sun)
            }
            Button("Apply") { apply(ConnectionSettings(mode: mode, host: cleanHost ?? "", port: cleanPort ?? 502, refresh: refresh)) }
                .keyboardShortcut(.defaultAction)
                .disabled(mode == .gx && (cleanHost == nil || cleanPort == nil))
        }
        .padding(13).card()
    }
}

private extension View {
    func card() -> some View {
        background(surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(rule, lineWidth: 1).allowsHitTesting(false) }
    }
}

private struct BluetoothDeviceCard: View {
    let device: BluetoothDevice
    let now: Date
    let editing: Bool
    let edit: () -> Void
    let save: ([UInt8]) throws -> Void
    let forget: () throws -> Void
    @State private var key = ""
    @State private var error: String?
    @State private var confirmForget = false

    private var status: String {
        switch device.status {
        case .needsKey: "Advertisement key needed"
        case .waiting: "Waiting for a fresh broadcast"
        case .reading: device.live(at: now) ? "Receiving" : "Out of range or paused"
        case .keyMismatch: "Advertisement key changed or does not match"
        case .noReadings: "No supported readings in this broadcast"
        case .unsupported: "Unsupported Instant Readout record"
        case .keychainUnavailable: "Could not read the saved Keychain item"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("\(device.typeName) · \(device.id.uuidString.suffix(4))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if device.status != .unsupported {
                    Button(editing ? "Cancel" : device.status == .needsKey ? "Add key" : "Key…") {
                        key = ""; error = nil; edit()
                    }.font(.caption)
                }
            }
            Text(status).font(.caption).foregroundStyle(device.live(at: now) ? mint : .secondary)
            if device.live(at: now), let v = device.values {
                Text(metrics(v)).font(.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            if editing {
                HStack {
                    SecureField("32-character advertisement key", text: $key).textFieldStyle(.roundedBorder)
                    Button("Paste", action: pasteKey)
                        .help("Paste the advertisement key from the clipboard")
                }
                HStack {
                    Button("Save key") {
                        if let bytes = InstantReadout.key(key) {
                            do { try save(bytes); key = ""; error = nil }
                            catch { self.error = error.localizedDescription }
                        } else { error = "Enter the 32 hexadecimal characters shown in VictronConnect." }
                    }
                    if device.status != .needsKey {
                        Button("Forget key") { confirmForget = true }
                            .confirmationDialog("Remove the saved advertisement key?", isPresented: $confirmForget) {
                                Button("Forget key", role: .destructive) {
                                    do { try forget(); key = ""; error = nil }
                                    catch { self.error = error.localizedDescription }
                                }
                            }
                    }
                }.font(.caption)
                if let error { Text(error).foregroundStyle(sun).font(.caption) }
            }
        }
        .padding(10).card()
        .onChange(of: editing) { isEditing in if !isEditing { key = ""; error = nil } }
    }

    private func pasteKey() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            error = "No text to paste. Copy the advertisement key first."
            return
        }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InstantReadout.key(candidate) != nil else {
            error = "The clipboard doesn’t contain a 32-character advertisement key."
            return
        }
        key = candidate
        error = nil
    }

    private func metrics(_ v: InstantReadout.Values) -> String {
        let values = [v.soc.map { String(format: "%.1f%%", $0) }, v.voltage.map { String(format: "%.2f V", $0) },
                      v.current.map { String(format: "%+.2f A", $0) }, v.solar.map { "PV " + watts($0) },
                      v.yield.map { String(format: "%.2f kWh today", $0) }, v.acOut.map { "Out " + watts($0) },
                      v.acIn.map { "In " + watts($0) }, v.apparent.map { voltAmps($0) + " out" },
                      v.acVoltage.map { String(format: "%.1f V AC", $0) }, v.acCurrent.map { String(format: "%.1f A AC", $0) },
                      v.inputVoltage.map { String(format: "%.2f V in", $0) }, v.inputCurrent.map { String(format: "%.1f A in", $0) },
                      v.temperature.map { String(format: "%.1f °C", $0) }, v.timeToGo.map { String(format: "%.0f min remaining", $0) }]
        let text = values.compactMap { $0 }.joined(separator: " · ")
        if !text.isEmpty { return text }
        switch v.state {
        case 0: return "Off"
        case 2: return "Fault"
        case 3: return "Bulk charging"
        case 4: return "Absorption"
        case 5: return "Float"
        case 9: return "Inverting"
        case let state?: return "Device state \(state)"
        default: return "No measurements available"
        }
    }
}
