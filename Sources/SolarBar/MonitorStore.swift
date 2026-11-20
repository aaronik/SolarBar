import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    struct State {
        var now = Date()
        var history: [Reading] = []
        var error: String?
        var devices: [BluetoothDevice] = []
        var batteryName: String?
        var acName: String?
        var latest: Reading?
        var dashboardWindow: TimeInterval { DashboardHistory.window(history, at: now) }
    }

    @Published private(set) var settings: ConnectionSettings
    @Published var menuDisplay = MenuDisplay.load(from: .standard) {
        didSet { menuDisplay.save(to: defaults) }
    }
    @Published private(set) var state = State()
    private var task: Task<Void, Never>?
    private let bluetooth = BluetoothMonitor()
    private let defaults = UserDefaults.standard
    let menuWindow: TimeInterval = 120

    var freshness: TimeInterval { max(12, Double(settings.refresh * 2 + 4)) }
    var isLive: Bool {
        if settings.mode == .bluetooth { return state.error == nil && state.history.last?.value != nil }
        guard let latest = state.latest else { return false }
        return state.error == nil && state.now.timeIntervalSince(latest.date) <= freshness
    }

    init() {
        let host = ConnectionSettings.cleanHost(defaults.string(forKey: "host") ?? "") ?? ""
        let port = UInt16(exactly: defaults.integer(forKey: "port")).flatMap { $0 > 0 ? $0 : nil } ?? 502
        let refresh = defaults.integer(forKey: "refresh")
        let saved = defaults.string(forKey: "source").flatMap(PowerSource.init(rawValue:))
        // Preserve an existing live GX configuration, but migrate the old default demo to Bluetooth.
        let mode = saved ?? (!host.isEmpty && defaults.object(forKey: "demo") as? Bool == false ? .gx : .bluetooth)
        settings = ConnectionSettings(mode: mode == .gx && host.isEmpty ? .bluetooth : mode,
                                      host: host, port: port, refresh: ConnectionSettings.refreshRange.contains(refresh) ? refresh : 5)
    }

    func apply(_ next: ConnectionSettings) {
        let reset = settings.mode != next.mode || (next.mode == .gx && (settings.host != next.host || settings.port != next.port))
        settings = next
        defaults.set(next.mode.rawValue, forKey: "source")
        defaults.set(next.host, forKey: "host")
        defaults.set(Int(next.port), forKey: "port")
        defaults.set(next.refresh, forKey: "refresh")
        start(reset: reset)
    }

    func setRefresh(_ seconds: Int) {
        guard ConnectionSettings.refreshRange.contains(seconds), seconds != settings.refresh else { return }
        var next = settings
        next.refresh = seconds
        apply(next)
    }

    func start(reset: Bool = false) {
        task?.cancel()
        let config = settings
        if config.mode == .bluetooth { bluetooth.start() } else { bluetooth.stop() }
        if reset { state = State() }
        if config.demo && state.history.isEmpty {
            let now = Date()
            let history = stride(from: (300 / config.refresh) * config.refresh, through: 0, by: -config.refresh).map {
                let date = now.addingTimeInterval(-Double($0))
                return Reading(date: date, value: .demo(at: date), refresh: config.refresh)
            }
            state = State(now: now, history: history, latest: history.last)
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let clock = ContinuousClock()
                let started = clock.now
                if config.mode != .bluetooth, let self { self.state.now = Date() }
                do {
                    let value: Telemetry
                    switch config.mode {
                    case .demo: value = .demo(at: Date())
                    case .gx: value = try await GXClient.sample(config)
                    case .bluetooth:
                        self?.recordBluetooth()
                        try? await clock.sleep(until: started.advanced(by: .seconds(config.refresh)))
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    self?.record(value: value, error: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.record(value: nil, error: error.localizedDescription)
                }
                try? await clock.sleep(until: max(started.advanced(by: .seconds(config.refresh)), clock.now.advanced(by: .seconds(1))))
            }
        }
    }

    private func recordBluetooth() {
        let now = Date()
        let devices = bluetooth.snapshot(at: now)
        let info = BluetoothSummary(devices: devices, at: now)
        let error = bluetooth.issue
        let anyLive = devices.contains { $0.live(at: now) }
        record(value: anyLive && error == nil ? info.telemetry : nil, error: error,
               at: now, devices: devices, batteryName: info.batteryName, acName: info.acName)
    }

    func saveBluetoothKey(_ key: [UInt8], for id: UUID) throws {
        try bluetooth.save(key, for: id)
        recordBluetooth()
    }

    func forgetBluetoothKey(_ id: UUID) throws {
        try bluetooth.forget(id)
        // Clear the old summaries so removed devices cannot leave a stale current reading.
        state = State()
        recordBluetooth()
    }

    private func record(value: Telemetry?, error: String?, at now: Date = Date(), devices: [BluetoothDevice] = [],
                        batteryName: String? = nil, acName: String? = nil) {
        let sample = Reading(date: now, value: value, refresh: settings.refresh)
        let history = DashboardHistory.retain(state.history + [sample], at: now)
        state = State(now: now, history: history, error: error, devices: devices,
                      batteryName: batteryName, acName: acName, latest: value == nil ? state.latest : sample)
    }

    func stop() { task?.cancel(); task = nil; bluetooth.stop() }
}
