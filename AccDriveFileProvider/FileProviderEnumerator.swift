import FileProvider

/// Enumerates a container's children and tracks external changes.
///
/// Initial listing is per-container (`enumerateItems`). Change detection runs
/// only in the **working set** enumerator: it re-fetches every browsed
/// project/folder, diffs against the last snapshot, and reports `didUpdate` /
/// `didDeleteItems`. Doing it globally (rather than per-container) is what lets
/// a move be told apart from a delete: an item that disappears from one folder
/// but reappears in another was moved, not deleted. The host app drives this by
/// periodically signalling the working set.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let containerRef: APSItemRef?
    private let client = APSClient.shared

    init(containerIdentifier: NSFileProviderItemIdentifier, containerRef: APSItemRef?) {
        self.containerIdentifier = containerIdentifier
        self.containerRef = containerRef
    }

    func invalidate() {}

    // MARK: - Initial enumeration

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        guard let containerRef else {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

        Task {
            do {
                let refs = try await children(of: containerRef)
                IdentifierStore.shared.save(refs)
                var snapshot: [String: String] = [:]
                for ref in refs { snapshot[ref.identifier.rawValue] = ref.changeSignature }
                IdentifierStore.shared.setChildSnapshot(snapshot, of: containerIdentifier)
                observer.didEnumerate(refs.map { FileProviderItem(ref: $0) })
                observer.finishEnumerating(upTo: nil)
            } catch {
                // A deleted folder returns 404; enumerate it as empty rather than
                // erroring, otherwise the system retries materialization forever
                // and can't apply the deletion.
                if case APSClient.APSError.server(let status, _) = error, status == 404 {
                    observer.didEnumerate([])
                    observer.finishEnumerating(upTo: nil)
                } else {
                    Log.fileProvider.error("Enumeration failed: \(error.localizedDescription, privacy: .public)")
                    observer.finishEnumeratingWithError(fileProviderError(error))
                }
            }
        }
    }

    // MARK: - Change tracking (working set only)

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard containerIdentifier == .workingSet else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        Task {
            // Only track changes inside projects and folders (file/subfolder
            // adds/updates/deletes). Tracking hub/root level produced failing
            // create-item jobs.
            let containers = IdentifierStore.shared.allSnapshotContainers().compactMap { id -> (NSFileProviderItemIdentifier, APSItemRef)? in
                guard let ref = IdentifierStore.shared.ref(for: id), ref.type == .project || ref.type == .folder else {
                    return nil
                }
                return (id, ref)
            }

            // Fetch everything first to build a global "still exists" set.
            var fetched: [(NSFileProviderItemIdentifier, [APSItemRef])] = []
            var globalIdentifiers = Set<String>()
            for (id, ref) in containers {
                guard let children = try? await children(of: ref) else { continue }
                fetched.append((id, children))
                for child in children { globalIdentifiers.insert(child.identifier.rawValue) }
            }

            var updated: [FileProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []
            for (id, children) in fetched {
                let old = IdentifierStore.shared.childSnapshot(of: id)
                var newSnapshot: [String: String] = [:]
                for child in children {
                    let key = child.identifier.rawValue
                    newSnapshot[key] = child.changeSignature
                    if old[key] != child.changeSignature {
                        updated.append(FileProviderItem(ref: child))
                    }
                }
                for key in old.keys where newSnapshot[key] == nil && !globalIdentifiers.contains(key) {
                    deleted.append(NSFileProviderItemIdentifier(key))
                }
                IdentifierStore.shared.save(children)
                IdentifierStore.shared.setChildSnapshot(newSnapshot, of: id)
            }

            Log.fileProvider.info("workingSet changes: \(updated.count) updated, \(deleted.count) deleted \(deleted.map { $0.rawValue }, privacy: .public)")
            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            // The anchor must advance once changes are reported, otherwise the
            // system rejects the batch (FP -1002) and stops applying changes.
            observer.finishEnumeratingChanges(upTo: Self.freshAnchor(), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.freshAnchor())
    }

    private static func freshAnchor() -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8))
    }

    private func children(of ref: APSItemRef) async throws -> [APSItemRef] {
        switch ref.type {
        case .root:
            return try await client.hubs()
        case .hub:
            return try await client.projects(hubId: ref.hubId ?? "")
        case .project:
            return try await client.topFolders(hubId: ref.hubId ?? "", projectId: ref.projectId ?? "")
        case .folder:
            return try await client.folderContents(hubId: ref.hubId, projectId: ref.projectId ?? "", folderId: ref.folderId ?? "")
        case .file:
            return []
        }
    }
}
