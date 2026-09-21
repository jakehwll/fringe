import Foundation

/// When to tell the user the pack is dying. Pure so the crossing can be
/// tested without posting a real notification — or a battery.
enum BatteryAlert {
    static let warn = 20
    static let critical = 10

    /// The threshold that just became true, if any. `already` is the set of
    /// alerts fired since the pack was last healthy, so plugging in and
    /// discharging again is a new event rather than a mute one.
    static func crossing(percent: Int, plugged: Bool, already: Set<Int>) -> Int? {
        guard !plugged else { return nil }
        if percent <= critical, !already.contains(critical) { return critical }
        if percent <= warn, !already.contains(warn), !already.contains(critical) { return warn }
        return nil
    }

    /// Plugged in, or climbed back above the warn line. Either is enough to
    /// forget what we already said.
    static func isRecovered(percent: Int, plugged: Bool) -> Bool {
        plugged || percent > warn
    }
}

/// A brief island when MagSafe goes on or off. First reading is a baseline,
/// not an event — launching the app should not look like you just plugged in.
enum BatteryPulse {
    static let duration: TimeInterval = 3.5

    static func shouldBegin(previous: Bool?, now: Bool) -> Bool {
        previous != nil && previous != now
    }
}
