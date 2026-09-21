import Foundation

/// What a script may touch. Declared on `widget({...})`, not inferred.
///
/// Network and local secrets cannot share a widget. Isolated contexts already
/// stop two scripts from reading each other's memory; this split is what
/// stops one gist from calling `notch.media()` and then `notch.fetch`. A
/// weather tile may talk to the internet. A player may see the session. Neither
/// may do both.
///
/// Declaration is not authorisation. The host intersects this with what the
/// user has granted in Settings before any host call succeeds. Bundled
/// examples are pre-granted so the first launch still works.
struct WidgetPermissions: Equatable, Sendable {
    var network = false
    var media = false
    var battery = false

    var mixesNetworkWithSecrets: Bool { network && (media || battery) }

    var labels: [String] {
        [network ? "Network" : nil, media ? "Media" : nil, battery ? "Battery" : nil]
            .compactMap { $0 }
    }

    /// Stable keys for UserDefaults and the on-disk permission marker.
    var keys: [String] {
        [network ? "network" : nil, media ? "media" : nil, battery ? "battery" : nil]
            .compactMap { $0 }
    }

    func intersection(_ granted: WidgetPermissions) -> WidgetPermissions {
        WidgetPermissions(
            network: network && granted.network,
            media: media && granted.media,
            battery: battery && granted.battery
        )
    }

    static func parse(_ value: Any?) -> WidgetPermissions {
        guard let object = value as? [AnyHashable: Any] else { return WidgetPermissions() }
        return WidgetPermissions(
            network: flag(object["network"]),
            media: flag(object["media"]),
            battery: flag(object["battery"])
        )
    }

    static func fromKeys(_ keys: [String]?) -> WidgetPermissions {
        guard let keys else { return WidgetPermissions() }
        return WidgetPermissions(
            network: keys.contains("network"),
            media: keys.contains("media"),
            battery: keys.contains("battery")
        )
    }

    private static func flag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
