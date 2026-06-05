import Foundation
import FileProvider

/// Canned demo data used when `MOCK_MODE` is enabled in Config.plist.
///
/// Lets the whole FileProvider pipeline (enumeration + on-demand download) be
/// exercised in Finder without a real ACC account or app authorization.
enum MockAPS {
    static func hubs() -> [APSItemRef] {
        [
            APSItemRef(type: .hub,
                       displayName: "Demo Construction Cloud",
                       hubId: "mockhub",
                       parentIdentifier: NSFileProviderItemIdentifier.rootContainer.rawValue),
        ]
    }

    static func projects(hubId: String) -> [APSItemRef] {
        let parent = APSItemRef(type: .hub, displayName: "", hubId: hubId).identifier.rawValue
        return ["Anthropic HQ - Zurich", "Merck - Eysins"].enumerated().map { index, name in
            APSItemRef(type: .project,
                       displayName: name,
                       hubId: hubId,
                       projectId: "mockproj\(index)",
                       parentIdentifier: parent)
        }
    }

    static func topFolders(hubId: String, projectId: String) -> [APSItemRef] {
        let parent = APSItemRef(type: .project, displayName: "", hubId: hubId, projectId: projectId).identifier.rawValue
        return [
            APSItemRef(type: .folder,
                       displayName: "Project Files",
                       hubId: hubId,
                       projectId: projectId,
                       folderId: "mockroot",
                       parentIdentifier: parent),
        ]
    }

    static func folderContents(projectId: String, folderId: String) -> [APSItemRef] {
        let parent = APSItemRef(type: .folder, displayName: "", projectId: projectId, folderId: folderId).identifier.rawValue

        func file(_ id: String, _ name: String) -> APSItemRef {
            var ref = APSItemRef(type: .file,
                                 displayName: name,
                                 projectId: projectId,
                                 itemId: id,
                                 versionId: "\(id)-v1",
                                 storageId: "mock:\(id)",
                                 parentIdentifier: parent)
            let content = fileContents(displayName: name)
            ref.fileSize = Int64(content.count)
            ref.modifiedAt = Date(timeIntervalSince1970: 1_716_000_000)
            return ref
        }

        if folderId == "mockroot" {
            return [
                APSItemRef(type: .folder,
                           displayName: "Drawings",
                           projectId: projectId,
                           folderId: "mockdrawings",
                           parentIdentifier: parent),
                file("mockfile-readme", "README.txt"),
                file("mockfile-rfi", "RFI-Log.txt"),
            ]
        }

        if folderId == "mockdrawings" {
            return [
                file("mockfile-plan", "Floor-Plan.txt"),
                file("mockfile-elev", "Elevations.txt"),
            ]
        }

        return []
    }

    /// Generated content returned by `fetchContents` for a mock file.
    static func fileContents(displayName: String) -> Data {
        let text = """
        AccDrive — demo file
        ====================

        Name: \(displayName)

        This file was served by AccDrive in MOCK_MODE, with no network call
        and no real Autodesk account. It demonstrates on-demand download:
        Finder showed a placeholder, and opening it triggered fetchContents,
        which wrote these bytes to a local temp file.

        Set MOCK_MODE to false in Config.plist to use the real APS API.
        """
        return Data(text.utf8)
    }
}
