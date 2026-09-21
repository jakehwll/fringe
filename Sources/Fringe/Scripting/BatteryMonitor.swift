import Foundation
import IOKit.ps
import Observation
@preconcurrency import UserNotifications

/// Live battery reading for the collapsed island, and the low-battery
/// notification. Independent of the widget render loop — scripts only tick
/// while the panel is open, which is exactly when you would *not* see the
/// island, and exactly when a "going flat" alert would fail to fire.
@MainActor
@Observable
final class BatteryMonitor {
    private(set) var snapshot: PowerSource.Snapshot?
    /// MagSafe just went on or off. Collapsed occupancy treats this as a
    /// brief battery island; going-flat is separate and stays up.
    private(set) var pulse = false

    var isPresent: Bool { snapshot != nil }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pulseTimer: Timer?
    @ObservationIgnored private var watcher: PowerSourceWatcher?
    @ObservationIgnored private var lastPlugged: Bool?
    @ObservationIgnored private var posted: Set<Int> = []
    @ObservationIgnored private var askedForPermission = false

    func start() {
        refresh()
        watcher = PowerSourceWatcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        watcher?.invalidate()
        watcher = nil
    }

    private func refresh() {
        let next = PowerSource.current()
        snapshot = next

        guard let next else {
            lastPlugged = nil
            endPulse()
            return
        }

        let plugged = next.isPlugged
        if BatteryPulse.shouldBegin(previous: lastPlugged, now: plugged) {
            beginPulse()
        }
        lastPlugged = plugged

        let percent = next.percent

        if BatteryAlert.isRecovered(percent: percent, plugged: plugged) {
            posted = []
            return
        }

        guard let threshold = BatteryAlert.crossing(
            percent: percent,
            plugged: plugged,
            already: posted
        ) else { return }

        posted.insert(threshold)
        notify(percent: percent, minutes: next.minutes, critical: threshold == BatteryAlert.critical)
    }

    private func beginPulse() {
        pulse = true
        pulseTimer?.invalidate()
        let timer = Timer(timeInterval: BatteryPulse.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endPulse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func endPulse() {
        pulse = false
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func notify(percent: Int, minutes: Int?, critical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = critical ? "Battery Critical" : "Battery Low"
        content.body = Self.body(percent: percent, minutes: minutes)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "battery.\(critical ? "critical" : "low")",
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        if askedForPermission {
            center.add(request)
            return
        }

        askedForPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            UNUserNotificationCenter.current().add(request)
        }
    }

    private static func body(percent: Int, minutes: Int?) -> String {
        if let minutes, minutes > 0 {
            let time: String
            if minutes < 60 {
                time = "\(minutes)m"
            } else {
                let hours = minutes / 60
                let rest = minutes % 60
                time = rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
            }
            return "\(percent)% remaining — about \(time) left."
        }
        return "\(percent)% remaining."
    }
}

/// IOKit delivers plug/unplug on a run-loop source, not on a timer. The
/// wrapper is not actor-isolated so the C callback can hold it.
private final class PowerSourceWatcher: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private var source: CFRunLoopSource?

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue().handler()
        }, pointer) else { return }
        let source = created.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    func invalidate() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
    }
}
