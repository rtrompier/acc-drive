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

    static let root = APSItemRef(type: .root, displayName: AppGroup.domainDisplayName)
}
