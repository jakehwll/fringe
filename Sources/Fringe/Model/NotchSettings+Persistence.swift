import Foundation
import Observation

@MainActor
extension NotchSettings {
    // MARK: - Persistence

    enum Default {
        static let columns = 6
        static let rows = 2
    }

    private enum Key {
        static let columns = "columns"
        static let rows = "rows"
        static let widgetOrder = "widgetOrder"
        static let widgetSpans = "widgetSpans"
        static let widgetPositions = "widgetPositions"
        static let disabledWidgets = "disabledWidgets"
        static let widgetValues = "widgetValues"
        static let widgetCapabilityGrants = "widgetCapabilityGrants"
    }

    /// Every key this build writes.
    ///
    /// The debug pane flags anything else it finds in the domain. A
    /// preference left behind by an older build is otherwise completely
    /// invisible, and will still be honoured by whatever code still reads it
    /// — which is exactly how `simulateNotch` cost an afternoon.
    nonisolated static let storedKeys = [
        Key.columns,
        Key.rows,
        Key.widgetOrder,
        Key.widgetSpans,
        Key.widgetPositions,
        Key.disabledWidgets,
        Key.widgetValues,
        Key.widgetCapabilityGrants
    ]

    /// What is actually in a preferences domain, with keys this build does
    /// not write called out. Apple's own keys are noise and are dropped.
    nonisolated static func inventory(of domain: [String: Any]) -> [StoredPreference] {
        let known = Set(storedKeys)
        return domain.keys.sorted().compactMap { key in
            guard !key.hasPrefix("NS"),
                  !key.hasPrefix("Apple"),
                  !key.hasPrefix("com.apple")
            else { return nil }
            return StoredPreference(
                key: key,
                value: stringify(domain[key]),
                isForeign: !known.contains(key)
            )
        }
    }

    private nonisolated static func stringify(_ value: Any?) -> String {
        switch value {
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map { stringify($0) }.joined(separator: ", ")
        case let dict as [String: Any]:
            return dict.keys.sorted().map { "\($0): \(stringify(dict[$0]))" }.joined(separator: "; ")
        case let string as String: return string
        case .none: return ""
        default: return String(describing: value!)
        }
    }

    func load() {
        // Left over from when simulating the notch was a user-facing toggle.
        // It silently replaced the measured cutout with a hardcoded guess.
        defaults.removeObject(forKey: "simulateNotch")

        if defaults.object(forKey: Key.columns) != nil {
            columns = Self.columnRange.clamping(defaults.integer(forKey: Key.columns))
        }
        if defaults.object(forKey: Key.rows) != nil {
            rows = Self.rowRange.clamping(defaults.integer(forKey: Key.rows))
        }
        widgetOrder = defaults.stringArray(forKey: Key.widgetOrder) ?? []
        widgetSpans = defaults.dictionary(forKey: Key.widgetSpans) as? [String: [Int]] ?? [:]
        widgetPositions = defaults.dictionary(forKey: Key.widgetPositions) as? [String: [Int]] ?? [:]
        disabledWidgets = Set(defaults.stringArray(forKey: Key.disabledWidgets) ?? [])
        widgetValues = defaults.dictionary(forKey: Key.widgetValues) as? [String: [String: Any]] ?? [:]
        if let stored = defaults.dictionary(forKey: Key.widgetCapabilityGrants) {
            widgetCapabilityGrants = stored.mapValues { ($0 as? [String]) ?? [] }
        } else {
            widgetCapabilityGrants = ExampleScripts.bundledGrants
        }
    }

    private func save() {
        defaults.set(columns, forKey: Key.columns)
        defaults.set(rows, forKey: Key.rows)
        defaults.set(widgetOrder, forKey: Key.widgetOrder)
        defaults.set(widgetSpans, forKey: Key.widgetSpans)
        defaults.set(widgetPositions, forKey: Key.widgetPositions)
        defaults.set(Array(disabledWidgets), forKey: Key.disabledWidgets)
        defaults.set(widgetValues, forKey: Key.widgetValues)
        defaults.set(widgetCapabilityGrants, forKey: Key.widgetCapabilityGrants)
    }

    /// `withObservationTracking` fires once, for the properties read in its body,
    /// so it has to be re-armed after every change.
    func persistOnChange() {
        withObservationTracking {
            _ = columns
            _ = rows
            _ = widgetOrder
            _ = widgetSpans
            _ = widgetPositions
            _ = disabledWidgets
            _ = widgetValues
            _ = widgetCapabilityGrants
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.save()
                self.persistOnChange()
            }
        }
    }
}
