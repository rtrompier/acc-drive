import Foundation

/// Provides a valid access token, refreshing it silently when needed.
///
/// Refreshes are single-flighted: concurrent callers awaiting an expired token
/// share one refresh network call.
actor TokenManager {
    static let shared = TokenManager()

    enum TokenError: Error {
        case notAuthenticated
    }

    private var refreshTask: Task<OAuthToken, Error>?

    /// Returns a non-expired access token, refreshing if necessary.
    func validAccessToken() async throws -> String {
        try await validToken().accessToken
    }

    func validToken() async throws -> OAuthToken {
        guard let token = TokenStore.load() else {
            throw TokenError.notAuthenticated
        }
        if !token.isExpired {
            return token
        }
        return try await refresh(token)
    }

    /// Forces a refresh (used after a 401 from the API).
    func forceRefresh() async throws -> OAuthToken {
        guard let token = TokenStore.load() else {
            throw TokenError.notAuthenticated
        }
        return try await refresh(token)
    }

    private func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        if let task = refreshTask {
            return try await task.value
        }

        let task = Task { () throws -> OAuthToken in
            defer { refreshTask = nil }
            guard !token.refreshToken.isEmpty else { throw TokenError.notAuthenticated }
            Log.auth.info("Refreshing access token")
            let new = try await APSAuth.refresh(token.refreshToken)
            TokenStore.save(new)
            return new
        }
        refreshTask = task
        return try await task.value
    }
}
