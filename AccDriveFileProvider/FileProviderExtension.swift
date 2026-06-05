import FileProvider
import UniformTypeIdentifiers

/// The principal class of the FileProvider extension.
///
/// Implements a read-only `NSFileProviderReplicatedExtension` backed by the APS
/// Data Management API. Write operations return an unsupported error.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        Log.fileProvider.info("Extension initialised for domain \(domain.displayName, privacy: .public)")
    }

    func invalidate() {}

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let ref = IdentifierStore.shared.ref(for: identifier) {
            completionHandler(FileProviderItem(ref: ref), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard let ref = IdentifierStore.shared.ref(for: itemIdentifier), ref.type == .file else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                if AppConfig.shared.mockMode {
                    let data = MockAPS.fileContents(displayName: ref.displayName)
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(ref.displayName)
                    try data.write(to: dest)
                    progress.completedUnitCount = 100
                    completionHandler(dest, FileProviderItem(ref: ref), nil)
                    return
                }

                let url = try await APSClient.shared.downloadURL(for: ref)
                progress.completedUnitCount = 30

                let (tempURL, _) = try await URLSession.shared.download(from: url)
                progress.completedUnitCount = 90

                // Move into a uniquely-named directory so the filename is preserved.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent(ref.displayName)
                try FileManager.default.moveItem(at: tempURL, to: dest)

                progress.completedUnitCount = 100
                completionHandler(dest, FileProviderItem(ref: ref), nil)
            } catch {
                Log.fileProvider.error("fetchContents failed for \(ref.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, fileProviderError(error))
            }
        }

        return progress
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet || containerItemIdentifier == .trashContainer {
            return FileProviderEnumerator(containerRef: nil)
        }
        guard let ref = IdentifierStore.shared.ref(for: containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return FileProviderEnumerator(containerRef: ref)
    }

    // MARK: - Mutations (read-only)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard let parentRef = IdentifierStore.shared.ref(for: itemTemplate.parentItemIdentifier),
              parentRef.type == .folder,
              let projectId = parentRef.projectId,
              let folderId = parentRef.folderId else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        let name = itemTemplate.filename
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true

        Task {
            do {
                let ref: APSItemRef
                if isFolder {
                    ref = try await APSClient.shared.createFolder(hubId: parentRef.hubId, projectId: projectId, parentFolderId: folderId, name: name)
                } else {
                    guard let contentsURL = url, let data = try? Data(contentsOf: contentsURL) else {
                        throw APSClient.APSError.notDownloadable
                    }
                    ref = try await APSClient.shared.uploadFile(hubId: parentRef.hubId, projectId: projectId, folderId: folderId, filename: name, data: data)
                }
                IdentifierStore.shared.save(ref)
                progress.completedUnitCount = 100
                completionHandler(FileProviderItem(ref: ref), [], false, nil)
            } catch {
                Log.fileProvider.error("createItem failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard var ref = IdentifierStore.shared.ref(for: item.itemIdentifier), let projectId = ref.projectId else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        // Resolve a move target up front (needs the new parent's folder id).
        var newParentFolderId: String?
        if changedFields.contains(.parentItemIdentifier),
           let parentRef = IdentifierStore.shared.ref(for: item.parentItemIdentifier),
           parentRef.type == .folder {
            newParentFolderId = parentRef.folderId
        }
        let newName: String? = changedFields.contains(.filename) ? item.filename : nil

        Task {
            do {
                // 1. Content edit and/or rename (a rename is a new version too).
                if ref.type == .file, let itemId = ref.itemId {
                    let finalName = newName ?? ref.displayName
                    if changedFields.contains(.contents), let folderId = ref.folderId,
                       let url = newContents, let data = try? Data(contentsOf: url) {
                        let versionId = try await APSClient.shared.addFileVersion(projectId: projectId, itemId: itemId, folderId: folderId, filename: finalName, data: data)
                        ref.versionId = versionId
                        ref.fileSize = Int64(data.count)
                        if let newName { ref.displayName = newName }
                    } else if let newName, let folderId = ref.folderId {
                        let versionId = try await APSClient.shared.renameItem(projectId: projectId, itemId: itemId, folderId: folderId, newName: newName, storageId: ref.storageId)
                        ref.versionId = versionId
                        ref.displayName = newName
                    }
                } else if ref.type == .folder, let newName, let folderId = ref.folderId {
                    try await APSClient.shared.patchFolder(projectId: projectId, folderId: folderId, name: newName, newParentFolderId: nil, hidden: nil)
                    ref.displayName = newName
                }

                // 2. Move (reparent).
                if let newParentFolderId {
                    switch ref.type {
                    case .file:
                        if let itemId = ref.itemId {
                            try await APSClient.shared.patchItem(projectId: projectId, itemId: itemId, displayName: nil, newParentFolderId: newParentFolderId)
                        }
                    case .folder:
                        if let folderId = ref.folderId {
                            try await APSClient.shared.patchFolder(projectId: projectId, folderId: folderId, name: nil, newParentFolderId: newParentFolderId, hidden: nil)
                        }
                    default:
                        break
                    }
                    ref.parentIdentifier = item.parentItemIdentifier.rawValue
                    if ref.type == .file { ref.folderId = newParentFolderId }
                }

                IdentifierStore.shared.save(ref)
                progress.completedUnitCount = 100
                completionHandler(FileProviderItem(ref: ref), [], false, nil)
            } catch {
                Log.fileProvider.error("modifyItem failed for \(ref.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, fileProviderError(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard let ref = IdentifierStore.shared.ref(for: identifier), let projectId = ref.projectId else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return progress
        }

        Task {
            do {
                switch ref.type {
                case .file:
                    if let itemId = ref.itemId {
                        try await APSClient.shared.deleteFileItem(projectId: projectId, itemId: itemId)
                    }
                case .folder:
                    if let folderId = ref.folderId {
                        try await APSClient.shared.deleteFolder(projectId: projectId, folderId: folderId)
                    }
                default:
                    completionHandler(readOnlyError)
                    return
                }
                IdentifierStore.shared.remove(identifier)
                progress.completedUnitCount = 100
                completionHandler(nil)
            } catch {
                Log.fileProvider.error("deleteItem failed for \(ref.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                completionHandler(fileProviderError(error))
            }
        }
        return progress
    }
}
