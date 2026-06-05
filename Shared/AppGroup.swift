import Foundation
import FileProvider

/// Shared constants and storage for the App Group used by both the host app
/// and the FileProvider extension.
enum AppGroup {
    static let identifier = "group.com.accdrive"

    /// FileProvider domain shown in Finder.
    static let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "com.accdrive.domain")
    static let domainDisplayName = "Autodesk Construction Cloud"

    /// UserDefaults shared across the App Group. Used for the identifier mapping.
    static var userDefaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: identifier) else {
            fatalError("Unable to open App Group UserDefaults for \(identifier). Check the App Group entitlement.")
        }
        return defaults
    }
}
