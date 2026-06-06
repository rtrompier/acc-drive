import Foundation
import FileProvider

/// Persistent `NSFileProviderItemIdentifier → APSItemRef` mapping.
///
/// Stored as one JSON file per identifier inside the process's **own** sandbox
/// container (Application Support), NOT the App Group container.
///
/// Why: the mapping is written and read entirely by the FileProvider extension
/// (the enumerator writes it; `item(for:)` / `fetchContents` read it). The host
/// app never reads it. The extension is recycled frequently by macOS, so the
/// mapping must persist on disk to survive process restarts — otherwise
/// `item(for:)` returns `.noSuchItem` after a recycle and Finder removes the
/// item. The App Group container is unusable here (the extension is denied
/// access to it on this signing team), but the extension's own container always
/// works and persists across its process lifecycle.
final class IdentifierStore {
    static let shared = IdentifierStore()

    private let directory: URL
    private let snapshotDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("AccDriveIdentifiers", isDirectory: true)
        snapshotDirectory = base.appendingPathComponent("AccDriveSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Per-container snapshots (for change tracking)

    /// `childIdentifier → changeSignature` for the last enumeration of a container.
    func childSnapshot(of container: NSFileProviderItemIdentifier) -> [String: String] {
        guard let data = try? Data(contentsOf: snapshotURL(container.rawValue)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func setChildSnapshot(_ snapshot: [String: String], of container: NSFileProviderItemIdentifier) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL(container.rawValue), options: .atomic)
    }

    /// All containers that have been enumerated at least once.
    func allSnapshotContainers() -> [NSFileProviderItemIdentifier] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            let encoded = url.deletingPathExtension().lastPathComponent
            return decodeBase64URL(encoded).map { NSFileProviderItemIdentifier($0) }
        }
    }

    func ref(for identifier: NSFileProviderItemIdentifier) -> APSItemRef? {
        if identifier == .rootContainer {
            return .root
        }
        guard let data = try? Data(contentsOf: fileURL(for: identifier.rawValue)) else {
            return nil
        }
        return try? JSONDecoder().decode(APSItemRef.self, from: data)
    }

    func save(_ ref: APSItemRef) {
        save([ref])
    }

    func save(_ refs: [APSItemRef]) {
        let encoder = JSONEncoder()
        for ref in refs where ref.type != .root {
            guard let data = try? encoder.encode(ref) else { continue }
            try? data.write(to: fileURL(for: ref.identifier.rawValue), options: .atomic)
        }
    }

    func remove(_ identifier: NSFileProviderItemIdentifier) {
        try? FileManager.default.removeItem(at: fileURL(for: identifier.rawValue))
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for rawIdentifier: String) -> URL {
        directory.appendingPathComponent(encodeBase64URL(rawIdentifier)).appendingPathExtension("json")
    }

    private func snapshotURL(_ rawIdentifier: String) -> URL {
        snapshotDirectory.appendingPathComponent(encodeBase64URL(rawIdentifier)).appendingPathExtension("json")
    }

    private func encodeBase64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeBase64URL(_ string: String) -> String? {
        var s = string.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
