import Foundation

/// Minimal JSON:API decoding for the APS Data Management responses.
///
/// All list endpoints return `{ "data": [ ... ], "included": [ ... ] }`.
/// Single-resource endpoints return `{ "data": { ... } }`.

struct JSONAPIList: Decodable {
    let data: [JSONAPIResource]
    let included: [JSONAPIResource]?
    let meta: JSONAPIMeta?
}

/// Top-level `meta` block. APS uses it to report partial failures (e.g. a hub
/// region the app is not authorized for) as warnings while still returning 200.
struct JSONAPIMeta: Decodable {
    let warnings: [JSONAPIWarning]?
}

struct JSONAPIWarning: Decodable {
    let statusCode: String?
    let errorCode: String?
    let title: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "HttpStatusCode"
        case errorCode = "ErrorCode"
        case title = "Title"
        case detail = "Detail"
    }
}

extension JSONAPIMeta {
    /// A user-facing message if the response carries a permission/403 warning.
    var permissionWarning: String? {
        guard let warnings, !warnings.isEmpty else { return nil }
        let permission = warnings.first { warning in
            warning.statusCode == "403"
                || (warning.detail?.localizedCaseInsensitiveContains("permission") ?? false)
        }
        let chosen = permission ?? warnings.first
        return chosen?.detail ?? chosen?.title
    }
}

struct JSONAPISingle: Decodable {
    let data: JSONAPIResource
    let included: [JSONAPIResource]?
}

struct JSONAPIResource: Decodable {
    let type: String
    let id: String
    let attributes: APSAttributes?
    let relationships: APSRelationships?
}

struct APSAttributes: Decodable {
    let name: String?
    let displayName: String?
    let storageSize: Int64?
    let fileType: String?
    let mimeType: String?
    let lastModifiedTime: String?
    let createTime: String?
    let `extension`: APSExtension?
}

struct APSExtension: Decodable {
    let type: String?
}

struct APSRelationships: Decodable {
    let tip: APSRelationship?
    let storage: APSRelationship?
    let derivatives: APSRelationship?
}

struct APSRelationship: Decodable {
    let data: APSRelationshipData?
}

struct APSRelationshipData: Decodable {
    let type: String?
    let id: String?
}

extension APSAttributes {
    /// Best display name for a resource.
    var bestName: String? {
        displayName ?? name
    }

    var modifiedDate: Date? {
        guard let raw = lastModifiedTime ?? createTime else { return nil }
        return APSDate.parse(raw)
    }
}

/// ISO8601 parser tolerant of fractional seconds.
enum APSDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
