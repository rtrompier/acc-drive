import FileProvider

/// Enumerates the children of a container by calling the APS API and mapping the
/// results to `NSFileProviderItem`s.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    /// The container being enumerated, or `nil` for empty containers
    /// (working set / trash).
    private let containerRef: APSItemRef?
    private let client = APSClient.shared

    init(containerRef: APSItemRef?) {
        self.containerRef = containerRef
    }

    func invalidate() {}

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
                let items = refs.map { FileProviderItem(ref: $0) }
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                Log.fileProvider.error("Enumeration failed: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(fileProviderError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // No incremental change tracking: report no changes. Finder picks up new
        // content on the next full enumeration (e.g. on refresh).
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("v1".utf8)))
    }

    // MARK: - Mapping containers to API calls

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
