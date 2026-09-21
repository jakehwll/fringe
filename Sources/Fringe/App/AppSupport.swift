import Foundation

/// On-disk home for widgets and their data. The leaf folders used to live
/// under `NotchApp`; first launch after the rename moves them if the new
/// path is empty, so a developer machine does not start from a blank board.
enum AppSupport {
    static let name = "Fringe"
    private static let legacyName = "NotchApp"

    static func folder(_ leaf: String) -> URL {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support")
        let current = support.appending(path: name).appending(path: leaf)
        let legacy = support.appending(path: legacyName).appending(path: leaf)
        if !fm.fileExists(atPath: current.path),
           fm.fileExists(atPath: legacy.path) {
            try? fm.createDirectory(
                at: current.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.moveItem(at: legacy, to: current)
        }
        return current
    }
}
