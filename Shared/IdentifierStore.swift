import Foundation
import FileProvider

/// Persistent `[NSFileProviderItemIdentifier: APSItemRef]` mapping, stored in the
/// App Group UserDefaults so the host app and the extension share it.
final class IdentifierStore {
    static let shared = IdentifierStore()

    private let defaults = AppGroup.userDefaults
    private let key = "identifierMap"
    private let lock = NSLock()

    private init() {}

    func ref(for identifier: NSFileProviderItemIdentifier) -> APSItemRef? {
        if identifier == .rootContainer {
            return .root
        }
        lock.lock(); defer { lock.unlock() }
        guard let map = defaults.dictionary(forKey: key) as? [String: Data],
              let data = map[identifier.rawValue]
        else { return nil }
        return try? JSONDecoder().decode(APSItemRef.self, from: data)
    }

    func save(_ ref: APSItemRef) {
        save([ref])
    }

    func save(_ refs: [APSItemRef]) {
        guard !refs.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var map = (defaults.dictionary(forKey: key) as? [String: Data]) ?? [:]
        let encoder = JSONEncoder()
        for ref in refs where ref.type != .root {
            if let data = try? encoder.encode(ref) {
                map[ref.identifier.rawValue] = data
            }
        }
        defaults.set(map, forKey: key)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
