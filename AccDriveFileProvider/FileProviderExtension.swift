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

        // Folder creation is not supported yet — only file upload.
        if itemTemplate.contentType?.conforms(to: .folder) == true {
            completionHandler(nil, [], false, readOnlyError)
            return progress
        }

        guard let parentRef = IdentifierStore.shared.ref(for: itemTemplate.parentItemIdentifier),
              parentRef.type == .folder,
              let projectId = parentRef.projectId,
              let folderId = parentRef.folderId else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return progress
        }

        guard let contentsURL = url, let data = try? Data(contentsOf: contentsURL) else {
            completionHandler(nil, [], false, readOnlyError)
            return progress
        }

        let filename = itemTemplate.filename
        Task {
            do {
                let ref = try await APSClient.shared.uploadFile(hubId: parentRef.hubId,
                                                                projectId: projectId,
                                                                folderId: folderId,
                                                                filename: filename,
                                                                data: data)
                IdentifierStore.shared.save(ref)
                progress.completedUnitCount = 100
                completionHandler(FileProviderItem(ref: ref), [], false, nil)
            } catch {
                Log.fileProvider.error("createItem upload failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
        completionHandler(nil, [], false, readOnlyError)
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(readOnlyError)
        return Progress()
    }
}
