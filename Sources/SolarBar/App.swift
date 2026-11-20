import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class SolarBarApp: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var subscription: AnyCancellable?

    static func main() {
        let app = NSApplication.shared
        let delegate = SolarBarApp()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        let item = NSStatusBar.system.statusItem(withLength: StatusGraph.emptyWidth + 6)
        self.item = item
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        item.button?.setAccessibilityLabel("SolarBar power monitor")
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Dashboard(store: store))
        popover.appearance = NSAppearance(named: .darkAqua)
        subscription = store.$state.combineLatest(store.$menuDisplay.removeDuplicates()).sink { [weak self] state, display in
            self?.render(state, display: display)
        }
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) { store.stop() }

    private func installEditMenu() {
        // Accessory apps have no visible menu bar, but AppKit still uses the main
        // menu's key equivalents to route Cmd+V, Cmd+A, etc. to the active field.
        let menu = NSMenu()
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        // The first submenu is reserved for the application menu by AppKit.
        let app = NSMenuItem(title: "SolarBar", action: nil, keyEquivalent: "")
        app.submenu = NSMenu(title: "SolarBar")
        menu.addItem(app)
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            let height = min(518, (button.window?.screen?.visibleFrame.height ?? 750) - 24)
            popover.contentSize = NSSize(width: 352, height: height)
            if #available(macOS 14, *) { NSApp.activate() }
            else { NSApp.activate(ignoringOtherApps: true) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func render(_ state: MonitorStore.State, display: MenuDisplay) {
        guard let item, let button = item.button else { return }
        let latest = state.latest
        let value = latest?.value
        let fresh = latest.map { state.now.timeIntervalSince($0.date) <= store.freshness } ?? false
        let hasCurrent = store.settings.mode == .bluetooth ? state.history.last?.value != nil : fresh
        let active = state.error == nil && hasCurrent
        let label = active ? (value?.soc.map { "\(Int($0.rounded()))%" } ?? "—") : "—"
        let source: String
        switch store.settings.mode {
        case .demo: source = "Demo"
        case .gx: source = active ? "Live GX" : state.error == nil ? "Connecting to GX" : "GX offline"
        case .bluetooth: source = active ? "Live Bluetooth" : state.error ?? "Listening for Victron Bluetooth readings"
        }
        let ac = value?.load != nil || value?.apparentLoad != nil
            ? (value?.acDisplay ?? "—")
            : (value?.acVoltageDisplay.map { "\($0) · load not broadcast" } ?? "—")
        let description = active ? "\(source) · Battery \(label) · Battery power \(signedWatts(value?.batteryPower)) · Solar \(watts(value?.solar)) · \(store.settings.mode == .bluetooth ? "AC output" : "AC load") \(ac)" : source
        let image = StatusGraph.image(state: state, window: store.menuWindow, gap: Double(store.settings.refresh) * 1.8 + 4,
                                         display: display, demo: store.settings.demo, active: active)
        let width = image.size.width + 6
        if item.length != width { item.length = width }
        button.image = image
        button.toolTip = description
        button.setAccessibilityValue(description)
    }
}

@MainActor
private enum StatusGraph {
    static let emptyWidth: CGFloat = 14
    static let graphWidth: CGFloat = 55

    static func image(state: MonitorStore.State, window: TimeInterval, gap: TimeInterval,
                      display: MenuDisplay, demo: Bool, active: Bool) -> NSImage {
        let samples = state.history.filter { state.now.timeIntervalSince($0.date) <= window }
        let ceiling = Timeline.powerCeiling(samples, solar: display.solar, ac: display.ac)
        let sun = display.solar ? Timeline.segments(samples, metric: \.solar, ending: state.now, window: window, maxGap: gap) : []
        let load = display.ac ? Timeline.segments(samples, metric: \.load, ending: state.now, window: window, maxGap: gap) : []
        let apparent = display.ac ? Timeline.segments(samples, metric: \.apparentLoad, ending: state.now, window: window, maxGap: gap) : []
        let apparentCeiling = Timeline.apparentCeiling(samples)
        let battery = display.battery ? Timeline.segments(samples, metric: \.soc, ending: state.now, window: window, maxGap: gap) : []
        let batteryPower = display.batteryPower ? Timeline.segments(samples, metric: \.batteryPower, ending: state.now, window: window, maxGap: gap) : []
        let batteryPowerRange = Timeline.batteryPowerRange(samples)
        let hasVisibleData = [sun, load, apparent, battery, batteryPower].contains { !$0.isEmpty }
        return NSImage(size: NSSize(width: hasVisibleData ? graphWidth : emptyWidth, height: 20), flipped: false) { _ in
            if hasVisibleData {
                let graph = CGRect(x: 2, y: 4, width: 51, height: 12)
                NSColor.labelColor.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: graph.insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3).fill()
                if !batteryPower.isEmpty {
                    let zero = NSBezierPath()
                    zero.move(to: CGPoint(x: graph.minX, y: graph.midY))
                    zero.line(to: CGPoint(x: graph.maxX, y: graph.midY))
                    zero.lineWidth = 0.5
                    NSColor.labelColor.withAlphaComponent(0.30).setStroke()
                    zero.stroke()
                }
                draw(sun, in: graph, range: 0...ceiling, color: .systemOrange, alpha: active ? 1 : 0.48)
                draw(load, in: graph, range: 0...ceiling, color: .systemPurple, alpha: active ? 1 : 0.48)
                draw(apparent, in: graph, range: 0...apparentCeiling, color: .systemPurple, alpha: active ? 1 : 0.48)
                draw(battery, in: graph, range: 0...100, color: .systemMint, alpha: active ? 1 : 0.48)
                draw(batteryPower, in: graph, range: batteryPowerRange, color: .systemBlue, alpha: active ? 1 : 0.48)
            } else {
                // Keep an obvious click target when no enabled metric can be drawn.
                let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
                bolt?.draw(in: CGRect(x: 2, y: 5, width: 9, height: 11), from: .zero, operation: .sourceOver, fraction: active ? 1 : 0.55)
            }
            if demo {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: CGRect(x: hasVisibleData ? 51 : 6, y: hasVisibleData ? 0 : 2, width: 3, height: 3)).fill()
            }
            return true
        }
    }

    private static func draw(_ segments: [[CGPoint]], in rect: CGRect, range: ClosedRange<Double>, color: NSColor, alpha: Double) {
        color.withAlphaComponent(alpha).setStroke()
        color.withAlphaComponent(alpha).setFill()
        for segment in segments {
            let points = segment.map { point in
                let fraction = (point.y - range.lowerBound) / (range.upperBound - range.lowerBound)
                return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + max(0, min(1, fraction)) * rect.height)
            }
            guard let first = points.first else { continue }
            if points.count == 1 {
                NSBezierPath(ovalIn: CGRect(x: first.x - 1, y: first.y - 1, width: 2, height: 2)).fill()
            } else {
                let path = NSBezierPath()
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                path.lineWidth = 1.45
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }
    }
}
