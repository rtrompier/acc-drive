import FileProvider
import UniformTypeIdentifiers

/// Maps an `APSItemRef` to an `NSFileProviderItem` understood by Finder.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let ref: APSItemRef

    init(ref: APSItemRef) {
        self.ref = ref
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        ref.identifier
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if let parent = ref.parentIdentifier, !parent.isEmpty {
            return NSFileProviderItemIdentifier(rawValue: parent)
        }
        return .rootContainer
    }

    var filename: String {
        ref.displayName.isEmpty ? ref.identifier.rawValue : ref.displayName
    }

    var contentType: UTType {
        guard ref.type == .file else { return .folder }
        let ext = (ref.displayName as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        switch ref.type {
        case .file:
            return [.allowsReading]
        case .folder:
            // Real ACC folders accept new files (upload).
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        default:
            // root / hub / project are navigational containers only.
            return [.allowsReading, .allowsContentEnumerating]
        }
    }

    var documentSize: NSNumber? {
        ref.fileSize.map { NSNumber(value: $0) }
    }

    var contentModificationDate: Date? {
        ref.modifiedAt
    }

    /// Required for replicated extensions. Both components must be <= 128 bytes.
    var itemVersion: NSFileProviderItemVersion {
        let content = ref.versionId ?? ref.storageId ?? ref.identifier.rawValue
        let metadata = ref.versionId ?? "\(ref.displayName):\(ref.fileSize ?? 0)"
        return NSFileProviderItemVersion(
            contentVersion: Self.versionData(content),
            metadataVersion: Self.versionData(metadata)
        )
    }

    /// Clamp version tokens to 128 bytes (FileProvider requirement).
    private static func versionData(_ string: String) -> Data {
        let data = Data(string.utf8)
        return data.count <= 128 ? data : data.suffix(128)
    }
}
