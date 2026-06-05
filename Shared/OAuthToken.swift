import Foundation

/// OAuth token set persisted in the Keychain.
struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    /// Treat the token as expired a minute early to leave room for clock skew
    /// and in-flight requests.
    var isExpired: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }

    init(accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = Date().addingTimeInterval(expiresIn)
    }

    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Persistence for the OAuth token, shared between the app and the extension
/// through the Keychain.
enum TokenStore {
    private static let account = "aps.oauth.token"

    static func load() -> OAuthToken? {
        guard let data = KeychainHelper.get(account: account) else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    static func save(_ token: OAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        try? KeychainHelper.set(data, account: account)
    }

    static func clear() {
        KeychainHelper.delete(account: account)
    }
}
