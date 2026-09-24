import Foundation

/// Bundled widget scripts, copied into the user's scripts folder on first
/// launch. The JavaScript lives in `Examples/` at the repo root and is
/// assembled into `Contents/Resources/Examples` — this is only the inventory
/// and the loader.
enum ExampleScripts {
    struct Example {
        let filename: String
        let source: String
    }

    /// Default board order. New files fall in after these, alphabetically.
    static let filenames = [
        "nowplaying.js",
        "weather.js",
        "clock.js",
        "battery.js",
        "hello.js"
    ]

    /// First-launch grants for bundled examples. A gist the user drops in
    /// later is not on this list, so network and media stay off until they
    /// flip the toggle in Settings.
    static let bundledGrants: [String: [String]] = [
        "nowplaying.js": ["media"],
        "weather.js": ["network"],
        "battery.js": ["battery"]
    ]

    static var all: [Example] {
        filenames.compactMap { filename in
            guard let source = contents(of: filename) else { return nil }
            return Example(filename: filename, source: source)
        }
    }

    static func contents(of filename: String) -> String? {
        guard let url = folder?.appending(path: filename) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `Contents/Resources/Examples` in the assembled app.
    static var folder: URL? {
        Bundle.main.resourceURL?.appending(path: "Examples")
    }
}
