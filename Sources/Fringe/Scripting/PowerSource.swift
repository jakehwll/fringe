import Foundation
import IOKit.ps

/// Battery reading exposed to scripts as `notch.battery()`.
enum PowerSource {
    struct Snapshot {
        var level: Double
        var isCharging: Bool
        var isCharged: Bool
        var isAC: Bool
        /// Minutes to full while charging, or to empty on battery. Nil when
        /// IOKit is still estimating, or when the pack is full on the adapter.
        var minutes: Int?

        var isPlugged: Bool { isCharging || isAC || isCharged }
        var percent: Int { Int((level * 100).rounded()) }

        var scriptValue: [String: Any] {
            var value: [String: Any] = [
                "level": level,
                "charging": isCharging,
                "charged": isCharged,
                "ac": isAC
            ]
            if let minutes {
                value["minutes"] = minutes
            }
            return value
        }
    }

    static func current() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  let snapshot = Self.snapshot(from: info)
            else { continue }
            return snapshot
        }
        return nil
    }

    /// Pulled out of `current()` so a dictionary of IOPS keys can be tested
    /// without a live power source — desktops have none, and a CI agent
    /// should not have to.
    static func snapshot(from info: [String: Any]) -> Snapshot? {
        guard let current = int(info[kIOPSCurrentCapacityKey as String]),
              let capacity = int(info[kIOPSMaxCapacityKey as String]),
              capacity > 0
        else { return nil }

        let charging = bool(info[kIOPSIsChargingKey as String])
        let charged = bool(info[kIOPSIsChargedKey as String])
        let onAC = (info[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)

        let minutes: Int?
        if charging {
            minutes = saneMinutes(info[kIOPSTimeToFullChargeKey as String])
        } else if !onAC {
            minutes = saneMinutes(info[kIOPSTimeToEmptyKey as String])
        } else {
            minutes = nil
        }

        return Snapshot(
            level: Double(current) / Double(capacity),
            isCharging: charging,
            isCharged: charged,
            isAC: onAC,
            minutes: minutes
        )
    }

    /// IOKit reports unknown/calculating as a negative or a sentinel well
    /// past a day. Neither is a duration a widget should print.
    private static func saneMinutes(_ value: Any?) -> Int? {
        guard let minutes = int(value), minutes >= 0, minutes <= 24 * 60 else { return nil }
        return minutes
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
