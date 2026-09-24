import Foundation

/// On-disk home for widgets and their data. The leaf folders used to live
/// under `NotchApp`; first launch after the rename moves them if the new
/// path is empty, so a developer machine does not start from a blank board.
enum AppSupport {
    static let name = "Fringe"
    private static let legacyName = "NotchApp"

    static func folder(_ leaf: String) -> URL {
        let files = FileManager.default
        let support = files.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")
        let current = support.appending(path: name).appending(path: leaf)
        let legacy = support.appending(path: legacyName).appending(path: leaf)
        if !files.fileExists(atPath: current.path),
           files.fileExists(atPath: legacy.path) {
            try? files.createDirectory(
                at: current.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? files.moveItem(at: legacy, to: current)
        }
        return current
    }
}
