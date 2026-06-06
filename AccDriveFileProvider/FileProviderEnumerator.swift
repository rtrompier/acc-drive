import FileProvider

/// Enumerates a container's children and tracks changes between enumerations.
///
/// `enumerateItems` lists the container and records a snapshot (childId →
/// signature). `enumerateChanges` re-fetches, diffs against the snapshot, and
/// reports `didUpdate` / `didDeleteItems`. The working-set enumerator re-checks
/// every container that has been browsed, so external edits/deletes propagate
/// to Finder when the host signals it.
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
                recordSnapshot(refs, for: containerIdentifier)
                observer.didEnumerate(refs.map { FileProviderItem(ref: $0) })
                observer.finishEnumerating(upTo: nil)
            } catch {
                Log.fileProvider.error("Enumeration failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    // MARK: - Change tracking

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        Task {
            let containers: [(NSFileProviderItemIdentifier, APSItemRef)]
            if containerIdentifier == .workingSet {
                // Re-check every container that has been browsed.
                containers = IdentifierStore.shared.allSnapshotContainers().compactMap { id in
                    IdentifierStore.shared.ref(for: id).map { (id, $0) }
                }
            } else if let containerRef {
                containers = [(containerIdentifier, containerRef)]
            } else {
                containers = []
            }

            var updated: [FileProviderItem] = []
            var deleted: [NSFileProviderItemIdentifier] = []

            for (id, ref) in containers {
                guard let current = try? await children(of: ref) else { continue }
                let old = IdentifierStore.shared.childSnapshot(of: id)
                var newSnapshot: [String: String] = [:]
                for child in current {
                    let key = child.identifier.rawValue
                    newSnapshot[key] = child.changeSignature
                    if old[key] != child.changeSignature {
                        updated.append(FileProviderItem(ref: child))
                    }
                }
                for key in old.keys where newSnapshot[key] == nil {
                    deleted.append(NSFileProviderItemIdentifier(key))
                }
                IdentifierStore.shared.save(current)
                IdentifierStore.shared.setChildSnapshot(newSnapshot, of: id)
            }

            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("v1".utf8)))
    }

    // MARK: - Helpers

    private func recordSnapshot(_ refs: [APSItemRef], for container: NSFileProviderItemIdentifier) {
        var snapshot: [String: String] = [:]
        for ref in refs { snapshot[ref.identifier.rawValue] = ref.changeSignature }
        IdentifierStore.shared.setChildSnapshot(snapshot, of: container)
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
