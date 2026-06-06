import FileProvider

/// Enumerates a container's children and tracks external changes.
///
/// Modeled on Apple's FruitBasket sample: the **working set** enumerates every
/// known item (so the system treats them as members and honours
/// `didDeleteItems`), and change detection happens there by diffing each
/// browsed project/folder against its last snapshot. Doing it globally lets a
/// move be told apart from a delete (an item that disappears from one folder but
/// reappears in another was moved). The host periodically signals the working
/// set to drive this.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let containerRef: APSItemRef?
    private let domain: NSFileProviderDomain
    private let client = APSClient.shared

    init(containerIdentifier: NSFileProviderItemIdentifier, containerRef: APSItemRef?, domain: NSFileProviderDomain) {
        self.containerIdentifier = containerIdentifier
        self.containerRef = containerRef
        self.domain = domain
    }

    func invalidate() {}

    private var isWorkingSet: Bool { containerIdentifier == .workingSet }

    // MARK: - Initial enumeration

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // The working set lists every known item so the system tracks them as
        // members — required for didDeleteItems to take effect.
        if isWorkingSet {
            let items = IdentifierStore.shared.allRefs().map { FileProviderItem(ref: $0) }
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
            return
        }

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
                // A deleted folder returns 404 — enumerate it as empty instead of
                // erroring (otherwise the system retries materialization forever).
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

    // MARK: - Change tracking (working set)

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard isWorkingSet else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }

        Task {
            // Track changes inside projects and folders only (file & subfolder
            // adds/updates/deletes). Tracking the hub/root level makes the system
            // try to "create" the hub and fail with FP -1005, jamming the queue —
            // so new projects/hubs surface only on a full re-enumeration (sign
            // out/in), not via the live feed.
            let containers = IdentifierStore.shared.allSnapshotContainers().compactMap { id -> (NSFileProviderItemIdentifier, APSItemRef)? in
                guard let ref = IdentifierStore.shared.ref(for: id), ref.type == .project || ref.type == .folder else { return nil }
                return (id, ref)
            }

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
                    IdentifierStore.shared.remove(NSFileProviderItemIdentifier(key))
                }
                IdentifierStore.shared.save(children)
                IdentifierStore.shared.setChildSnapshot(newSnapshot, of: id)
            }

            let hasChanges = !updated.isEmpty || !deleted.isEmpty
            let anchorValue = hasChanges ? IdentifierStore.shared.bumpWorkingSetAnchor() : IdentifierStore.shared.workingSetAnchorValue()

            Log.fileProvider.info("workingSet changes: \(updated.count) updated, \(deleted.count) deleted (anchor \(anchorValue))")
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            if !updated.isEmpty { observer.didUpdate(updated) }
            observer.finishEnumeratingChanges(upTo: Self.anchorData(anchorValue), moreComing: false)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let value = isWorkingSet ? IdentifierStore.shared.workingSetAnchorValue() : 0
        completionHandler(Self.anchorData(value))
    }

    private static func anchorData(_ value: Int) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(value)".utf8))
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
