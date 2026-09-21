import Foundation

/// One field a widget declared so the user can edit it.
///
/// Scripts stay generic — they describe the field, the settings window draws
/// a control, and `notch.setting(key)` reads whatever the user typed. Without
/// this every widget that needs a city, a unit or a path has to hard-code it.
struct WidgetSettingSpec: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case string
        case number
        case boolean
        case choice
    }

    var id: String
    var kind: Kind
    var label: String
    var stringDefault = ""
    var numberDefault = 0.0
    var booleanDefault = false
    var options: [String] = []

    static func parse(_ value: Any?) -> [WidgetSettingSpec] {
        guard let object = value as? [AnyHashable: Any] else { return [] }

        return object.keys.compactMap { raw -> WidgetSettingSpec? in
            guard let id = raw as? String, !id.isEmpty,
                  let field = object[raw] as? [AnyHashable: Any]
            else { return nil }

            let kind = Kind(rawValue: field["type"] as? String ?? "string") ?? .string
            let label = field["label"] as? String ?? id
            var spec = WidgetSettingSpec(id: id, kind: kind, label: label)

            switch kind {
            case .string, .choice:
                spec.stringDefault = field["default"] as? String ?? ""
            case .number:
                spec.numberDefault = (field["default"] as? NSNumber)?.doubleValue ?? 0
            case .boolean:
                spec.booleanDefault = field["default"] as? Bool ?? false
            }

            spec.options = (field["options"] as? [Any] ?? []).compactMap { $0 as? String }
            if kind == .choice, spec.options.isEmpty { return nil }
            return spec
        }
        .sorted { $0.id < $1.id }
    }
}
