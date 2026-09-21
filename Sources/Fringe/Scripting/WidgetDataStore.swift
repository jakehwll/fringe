import Foundation

/// Per-widget files and key-value storage, sandboxed to one folder.
///
/// Scripts cannot see the rest of the disk. A path with a slash or `..` is
/// refused rather than resolved, because "just a filename" is the only
/// contract that stays safe when the author is the user.
struct WidgetDataStore: Sendable {
    let folder: URL

    static let maxFileBytes = 256 * 1024

    init(widgetID: String, root: URL) {
        folder = root.appending(path: Self.safeComponent(widgetID))
    }

    static func defaultRoot() -> URL {
        AppSupport.folder("WidgetData")
    }

    // MARK: - Key-value

    func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: storageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    func save(_ values: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(values) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted])
        else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    func get(_ key: String) -> Any? {
        load()[key]
    }

    func set(_ key: String, value: Any?) {
        var values = load()
        guard let value else {
            values.removeValue(forKey: key)
            save(values)
            return
        }
        guard JSONSerialization.isValidJSONObject(["v": value]) else { return }
        values[key] = value
        save(values)
    }

    // MARK: - Files

    func read(name: String) -> String? {
        guard let url = fileURL(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func write(name: String, contents: String) -> String? {
        guard let url = fileURL(name) else { return "Invalid file name" }
        guard let data = contents.data(using: .utf8), data.count <= Self.maxFileBytes else {
            return "File too large"
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A filename, nothing else. The store's folder is the only directory a
    /// script can touch; allowing a slash would make that a lie.
    static func fileURL(name: String, in folder: URL) -> URL? {
        guard isSafeFilename(name) else { return nil }
        return folder.appending(path: name)
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 64
            && !name.hasPrefix(".")
            && name != "storage.json"
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
            && !name.contains("..")
    }

    static func safeComponent(_ id: String) -> String {
        let trimmed = id.split(separator: "/").last.map(String.init) ?? id
        let safe = trimmed.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return String(safe).isEmpty ? "widget" : String(safe)
    }

    private var storageURL: URL { folder.appending(path: "storage.json") }

    private func fileURL(_ name: String) -> URL? {
        Self.fileURL(name: name, in: folder)
    }

    /// Widgets keep data under their filename. Replacing a media script with a
    /// network gist of the same name would otherwise inherit `storage.json`.
    /// The marker is host-owned (dotted names are not a legal `notch.write`).
    func alignDeclaredPermissions(_ permissions: WidgetPermissions) {
        let token = permissions.keys.joined(separator: ",")
        let previous = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let previous else {
            try? token.write(to: markerURL, atomically: true, encoding: .utf8)
            return
        }
        guard previous != token else { return }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? token.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private var markerURL: URL { folder.appending(path: ".permissions") }
}
