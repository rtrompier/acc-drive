import Foundation
import FileProvider

/// Wraps the APS Data Management and OSS APIs with async/await.
///
/// Handles bearer auth, refreshes on `401`, and retries `429`/`5xx` with
/// exponential backoff (max 3 attempts).
final class APSClient {
    static let shared = APSClient()

    private let baseURL = URL(string: "https://developer.api.autodesk.com")!
    private let session = URLSession(configuration: .ephemeral)
    private let tokenManager = TokenManager.shared

    enum APSError: Error {
        case notAuthenticated
        case invalidResponse
        case server(status: Int, body: String)
        case notDownloadable
        /// The user is authenticated but the app is not authorized for the account
        /// (e.g. ACC/BIM360 hub requiring a Custom Integration).
        case notAuthorizedForAccount(detail: String)
    }

    // MARK: - Public API

    /// Lists all hubs (ACC accounts) as folders at the root.
    func hubs() async throws -> [APSItemRef] {
        if AppConfig.shared.mockMode { return MockAPS.hubs() }
        let url = baseURL.appendingPathComponent("project/v1/hubs")
        let data = try await get(url)
        let doc = try JSONDecoder().decode(JSONAPIList.self, from: data)
        Log.aps.info("/hubs -> \(doc.data.count) hub(s)")

        // APS returns 200 with an empty data array and a 403 warning when the
        // app is not authorized for the account. Surface that instead of an
        // empty folder — but only when no hubs at all came back.
        if doc.data.isEmpty, let warning = doc.meta?.permissionWarning {
            Log.aps.error("hubs not authorized: \(warning, privacy: .public)")
            throw APSError.notAuthorizedForAccount(detail: warning)
        }

        return doc.data
            .filter { $0.type == "hubs" }
            .map { res in
                APSItemRef(type: .hub,
                           displayName: res.attributes?.bestName ?? res.id,
                           hubId: res.id,
                           parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)
            }
    }

    /// Lists the projects within a hub.
    func projects(hubId: String) async throws -> [APSItemRef] {
        if AppConfig.shared.mockMode { return MockAPS.projects(hubId: hubId) }
        let url = baseURL.appendingPathComponent("project/v1/hubs/\(hubId)/projects")
        let doc = try await getList(url)
        let parent = APSItemRef(type: .hub, displayName: "", hubId: hubId).identifier.rawValue
        return doc.data
            .filter { $0.type == "projects" }
            .map { res in
                APSItemRef(type: .project,
                           displayName: res.attributes?.bestName ?? res.id,
                           hubId: hubId,
                           projectId: res.id,
                           parentIdentifier: parent)
            }
    }

    /// Lists the top-level folders of a project.
    func topFolders(hubId: String, projectId: String) async throws -> [APSItemRef] {
        if AppConfig.shared.mockMode { return MockAPS.topFolders(hubId: hubId, projectId: projectId) }
        let url = baseURL.appendingPathComponent("project/v1/hubs/\(hubId)/projects/\(projectId)/topFolders")
        let doc = try await getList(url)
        let parent = APSItemRef(type: .project, displayName: "", hubId: hubId, projectId: projectId).identifier.rawValue
        return doc.data
            .filter { $0.type == "folders" }
            .map { res in
                APSItemRef(type: .folder,
                           displayName: res.attributes?.bestName ?? res.id,
                           hubId: hubId,
                           projectId: projectId,
                           folderId: res.id,
                           parentIdentifier: parent)
            }
    }

    /// Lists the contents of a folder: subfolders and file items.
    func folderContents(hubId: String?, projectId: String, folderId: String) async throws -> [APSItemRef] {
        if AppConfig.shared.mockMode { return MockAPS.folderContents(projectId: projectId, folderId: folderId) }
        let url = baseURL.appendingPathComponent("data/v1/projects/\(projectId)/folders/\(folderId)/contents")
        let doc = try await getList(url)
        let parent = APSItemRef(type: .folder, displayName: "", projectId: projectId, folderId: folderId).identifier.rawValue

        // Index included resources (tip versions) by id.
        let included = Dictionary(uniqueKeysWithValues: (doc.included ?? []).map { ($0.id, $0) })

        var refs: [APSItemRef] = []
        for res in doc.data {
            switch res.type {
            case "folders":
                refs.append(APSItemRef(type: .folder,
                                       displayName: res.attributes?.bestName ?? res.id,
                                       hubId: hubId,
                                       projectId: projectId,
                                       folderId: res.id,
                                       parentIdentifier: parent))
            case "items":
                let tipId = res.relationships?.tip?.data?.id
                let version = tipId.flatMap { included[$0] }
                let attrs = version?.attributes
                refs.append(APSItemRef(type: .file,
                                       displayName: res.attributes?.bestName ?? attrs?.bestName ?? res.id,
                                       hubId: hubId,
                                       projectId: projectId,
                                       itemId: res.id,
                                       versionId: tipId,
                                       storageId: version?.relationships?.storage?.data?.id,
                                       mimeType: attrs?.mimeType,
                                       fileSize: attrs?.storageSize,
                                       modifiedAt: attrs?.modifiedDate,
                                       parentIdentifier: parent))
            default:
                continue
            }
        }
        return refs
    }

    /// Resolves a temporary signed S3 download URL for a file item.
    func downloadURL(for ref: APSItemRef) async throws -> URL {
        var storageId = ref.storageId
        if storageId == nil, let projectId = ref.projectId, let itemId = ref.itemId {
            storageId = try await tipStorageId(projectId: projectId, itemId: itemId)
        }
        guard let storageId, let (bucket, object) = Self.parseStorageURN(storageId) else {
            throw APSError.notDownloadable
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/oss/v2/buckets/\(bucket)/objects/\(object)/signeds3download"
        guard let url = components.url else { throw APSError.notDownloadable }

        let data = try await get(url)
        let decoded = try JSONDecoder().decode(SignedDownload.self, from: data)
        guard let urlString = decoded.url, let signed = URL(string: urlString) else {
            // Chunked downloads (very large files) return `urls` instead of `url`.
            throw APSError.notDownloadable
        }
        return signed
    }

    // MARK: - Upload (write)

    /// Uploads a new file into a folder: creates OSS storage, uploads the bytes
    /// via signed S3 upload, then creates the item + first version.
    func uploadFile(hubId: String?, projectId: String, folderId: String, filename: String, data: Data) async throws -> APSItemRef {
        let storageURN = try await createStorage(projectId: projectId, folderId: folderId, filename: filename)
        try await uploadBytes(storageURN: storageURN, data: data)
        let (itemId, versionId) = try await createItemAndVersion(projectId: projectId, folderId: folderId, filename: filename, storageURN: storageURN)

        let parent = APSItemRef(type: .folder, displayName: "", projectId: projectId, folderId: folderId).identifier.rawValue
        var ref = APSItemRef(type: .file,
                             displayName: filename,
                             hubId: hubId,
                             projectId: projectId,
                             itemId: itemId,
                             versionId: versionId,
                             storageId: storageURN,
                             parentIdentifier: parent)
        ref.fileSize = Int64(data.count)
        return ref
    }

    private func createStorage(projectId: String, folderId: String, filename: String) async throws -> String {
        let url = baseURL.appendingPathComponent("data/v1/projects/\(projectId)/storage")
        let body: [String: Any] = [
            "jsonapi": ["version": "1.0"],
            "data": [
                "type": "objects",
                "attributes": ["name": filename],
                "relationships": ["target": ["data": ["type": "folders", "id": folderId]]],
            ],
        ]
        let data = try await post(url, body: try JSONSerialization.data(withJSONObject: body))
        let doc = try JSONDecoder().decode(JSONAPISingle.self, from: data)
        return doc.data.id
    }

    private func uploadBytes(storageURN: String, data: Data) async throws {
        guard let (bucket, object) = Self.parseStorageURN(storageURN) else { throw APSError.notDownloadable }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/oss/v2/buckets/\(bucket)/objects/\(object)/signeds3upload"
        guard let signURL = components.url else { throw APSError.notDownloadable }

        // 1. Ask OSS for a presigned PUT URL.
        let signData = try await get(signURL)
        let signed = try JSONDecoder().decode(SignedUpload.self, from: signData)
        guard let urlString = signed.urls?.first, let putURL = URL(string: urlString) else {
            throw APSError.notDownloadable
        }

        // 2. PUT the bytes directly to S3 (presigned, no auth header).
        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.httpBody = data
        let (_, putResponse) = try await session.data(for: put)
        guard let http = putResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APSError.server(status: (putResponse as? HTTPURLResponse)?.statusCode ?? -1, body: "S3 upload failed")
        }

        // 3. Finalize the upload.
        let completeBody: [String: Any] = ["uploadKey": signed.uploadKey]
        _ = try await post(signURL, body: try JSONSerialization.data(withJSONObject: completeBody), contentType: "application/json")
    }

    private func createItemAndVersion(projectId: String, folderId: String, filename: String, storageURN: String) async throws -> (itemId: String, versionId: String) {
        let url = baseURL.appendingPathComponent("data/v1/projects/\(projectId)/items")
        let body: [String: Any] = [
            "jsonapi": ["version": "1.0"],
            "data": [
                "type": "items",
                "attributes": [
                    "displayName": filename,
                    "extension": ["type": "items:autodesk.bim360:File", "version": "1.0"],
                ],
                "relationships": [
                    "tip": ["data": ["type": "versions", "id": "1"]],
                    "parent": ["data": ["type": "folders", "id": folderId]],
                ],
            ],
            "included": [[
                "type": "versions",
                "id": "1",
                "attributes": [
                    "name": filename,
                    "extension": ["type": "versions:autodesk.bim360:File", "version": "1.0"],
                ],
                "relationships": [
                    "storage": ["data": ["type": "objects", "id": storageURN]],
                ],
            ]],
        ]
        let data = try await post(url, body: try JSONSerialization.data(withJSONObject: body))
        let doc = try JSONDecoder().decode(JSONAPISingle.self, from: data)
        let itemId = doc.data.id
        let versionId = doc.data.relationships?.tip?.data?.id ?? doc.included?.first?.id ?? "1"
        return (itemId, versionId)
    }

    // MARK: - Private helpers

    private struct SignedDownload: Decodable {
        let url: String?
        let status: String?
    }

    private struct SignedUpload: Decodable {
        let uploadKey: String
        let urls: [String]?
    }

    private func tipStorageId(projectId: String, itemId: String) async throws -> String? {
        let url = baseURL.appendingPathComponent("data/v1/projects/\(projectId)/items/\(itemId)/versions")
        let doc = try await getList(url)
        // The first version is the tip.
        return doc.data.first?.relationships?.storage?.data?.id
    }

    private static func parseStorageURN(_ urn: String) -> (bucket: String, object: String)? {
        // urn:adsk.objects:os.object:<bucketKey>/<objectKey>
        guard let range = urn.range(of: "os.object:") else { return nil }
        let rest = urn[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let bucket = String(rest[..<slash])
        let object = String(rest[rest.index(after: slash)...])
        guard !bucket.isEmpty, !object.isEmpty else { return nil }
        return (bucket, object)
    }

    private func getList(_ url: URL) async throws -> JSONAPIList {
        let data = try await get(url)
        return try JSONDecoder().decode(JSONAPIList.self, from: data)
    }

    /// Performs an authorized GET with token refresh and backoff retry.
    func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return try await authedData(for: request)
    }

    /// Performs an authorized POST with token refresh and backoff retry.
    func post(_ url: URL, body: Data, contentType: String = "application/vnd.api+json") async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return try await authedData(for: request)
    }

    /// Core request loop: injects a fresh bearer token, refreshes on 401, and
    /// retries 429/5xx with exponential backoff (max 3 attempts).
    private func authedData(for baseRequest: URLRequest) async throws -> Data {
        let maxAttempts = 3
        var attempt = 0
        var didRefresh = false
        let label = baseRequest.url?.path ?? "?"

        while true {
            attempt += 1
            let token = try await tokenManager.validAccessToken()

            var request = baseRequest
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                Log.aps.error("Network error for \(label, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if attempt < maxAttempts {
                    try await backoff(attempt)
                    continue
                }
                throw error
            }

            guard let http = response as? HTTPURLResponse else { throw APSError.invalidResponse }

            switch http.statusCode {
            case 200..<300:
                Log.aps.info("\(request.httpMethod ?? "?", privacy: .public) \(label, privacy: .public) -> \(http.statusCode) (\(data.count) bytes)")
                return data
            case 401 where !didRefresh:
                Log.aps.info("401 received, refreshing token")
                didRefresh = true
                _ = try await tokenManager.forceRefresh()
                continue
            case 401:
                throw APSError.notAuthenticated
            case 429, 500..<600:
                if attempt < maxAttempts {
                    Log.aps.info("Retryable \(http.statusCode) for \(label, privacy: .public), attempt \(attempt)")
                    try await backoff(attempt)
                    continue
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                throw APSError.server(status: http.statusCode, body: body)
            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                Log.aps.error("APS error \(http.statusCode) for \(label, privacy: .public): \(body, privacy: .public)")
                throw APSError.server(status: http.statusCode, body: body)
            }
        }
    }

    private func backoff(_ attempt: Int) async throws {
        // 0.5s, 1s, 2s …
        let seconds = 0.5 * pow(2.0, Double(attempt - 1))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
