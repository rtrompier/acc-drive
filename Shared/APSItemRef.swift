import Foundation
import FileProvider

/// The kind of node in the ACC hierarchy mapped to a Finder item.
enum APSItemType: String, Codable {
    case root
    case hub
    case project
    case folder
    case file
}

/// A persistent reference to an APS entity, stored in the App Group and used to
/// resolve `NSFileProviderItemIdentifier`s back into API calls.
struct APSItemRef: Codable {
    var type: APSItemType
    var displayName: String

    var hubId: String?
    var projectId: String?
    var folderId: String?
    var itemId: String?
    var versionId: String?
    /// OSS storage URN of the tip version, used to build the download URL.
    var storageId: String?

    var mimeType: String?
    var fileSize: Int64?
    var modifiedAt: Date?

    /// Identifier of the parent container, for `parentItemIdentifier`.
    var parentIdentifier: String?

    // Explicit memberwise init (the custom init?(identifier:) below suppresses
    // the synthesized one).
    init(type: APSItemType,
         displayName: String,
         hubId: String? = nil,
         projectId: String? = nil,
         folderId: String? = nil,
         itemId: String? = nil,
         versionId: String? = nil,
         storageId: String? = nil,
         mimeType: String? = nil,
         fileSize: Int64? = nil,
         modifiedAt: Date? = nil,
         parentIdentifier: String? = nil) {
        self.type = type
        self.displayName = displayName
        self.hubId = hubId
        self.projectId = projectId
        self.folderId = folderId
        self.itemId = itemId
        self.versionId = versionId
        self.storageId = storageId
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.parentIdentifier = parentIdentifier
    }

    // MARK: - Identifiers

    /// Stable FileProvider identifier for this reference.
    var identifier: NSFileProviderItemIdentifier {
        switch type {
        case .root:
            return .rootContainer
        case .hub:
            return NSFileProviderItemIdentifier("hub:\(hubId ?? "")")
        case .project:
            return NSFileProviderItemIdentifier("project:\(hubId ?? ""):\(projectId ?? "")")
        case .folder:
            return NSFileProviderItemIdentifier("folder:\(projectId ?? ""):\(folderId ?? "")")
        case .file:
            return NSFileProviderItemIdentifier("file:\(projectId ?? ""):\(itemId ?? "")")
        }
    }

    /// Fingerprint used to detect changes between enumerations. Changes whenever
    /// a file gets a new version, an item is renamed, resized, or moved.
    var changeSignature: String {
        "\(type.rawValue)|\(versionId ?? "")|\(displayName)|\(fileSize ?? -1)|\(parentIdentifier ?? "")"
    }

    /// Reconstructs an identity-only ref (type + ids, no metadata) from an
    /// identifier. Parent is derivable for hub/project; folder/file need an API
    /// lookup for their parent and name.
    init?(identifier: NSFileProviderItemIdentifier) {
        if identifier == .rootContainer {
            self = .root
            return
        }
        let raw = identifier.rawValue
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let kind = String(raw[..<colon])
        let rest = String(raw[raw.index(after: colon)...])

        func split2(_ s: String) -> (String, String)? {
            guard let c = s.firstIndex(of: ":") else { return nil }
            return (String(s[..<c]), String(s[s.index(after: c)...]))
        }

        switch kind {
        case "hub":
            self = APSItemRef(type: .hub, displayName: "", hubId: rest,
                              parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue)
        case "project":
            guard let (hubId, projectId) = split2(rest) else { return nil }
            let parent = APSItemRef(type: .hub, displayName: "", hubId: hubId).identifier.rawValue
            self = APSItemRef(type: .project, displayName: "", hubId: hubId, projectId: projectId, parentIdentifier: parent)
        case "folder":
            guard let (projectId, folderId) = split2(rest) else { return nil }
            self = APSItemRef(type: .folder, displayName: "", projectId: projectId, folderId: folderId)
        case "file":
            guard let (projectId, itemId) = split2(rest) else { return nil }
            self = APSItemRef(type: .file, displayName: "", projectId: projectId, itemId: itemId)
        default:
            return nil
        }
    }

    static let root = APSItemRef(type: .root, displayName: AppGroup.domainDisplayName)
}
