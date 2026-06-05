import Foundation

/// Low-level Authentication (v2) endpoint calls for Autodesk Platform Services.
enum APSAuth {
    static let baseURL = URL(string: "https://developer.api.autodesk.com")!
    static let scopes = "data:read data:write viewables:read"

    enum AuthError: Error {
        case invalidResponse
        case server(status: Int, body: String)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
    }

    static var authorizeEndpoint: URL {
        baseURL.appendingPathComponent("authentication/v2/authorize")
    }

    static var tokenEndpoint: URL {
        baseURL.appendingPathComponent("authentication/v2/token")
    }

    /// Builds the authorization URL opened in the browser for the 3-legged flow.
    static func authorizationURL(state: String) -> URL {
        let config = AppConfig.shared
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// Exchanges an authorization code for a token set (interactive login).
    static func exchangeCode(_ code: String) async throws -> OAuthToken {
        let config = AppConfig.shared
        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
        ]
        return try await postToken(body)
    }

    /// Refreshes an expired token using the refresh token.
    static func refresh(_ refreshToken: String) async throws -> OAuthToken {
        let body = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scopes,
        ]
        return try await postToken(body, previousRefreshToken: refreshToken)
    }

    // MARK: - Private

    private static func postToken(_ fields: [String: String], previousRefreshToken: String? = nil) async throws -> OAuthToken {
        let config = AppConfig.shared
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Confidential client: HTTP Basic auth with client_id:client_secret.
        let credentials = "\(config.clientId):\(config.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        request.httpBody = formURLEncode(fields).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.auth.error("Token request failed (\(http.statusCode)): \(body, privacy: .public)")
            throw AuthError.server(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        // APS does not always return a new refresh token on refresh; keep the old one.
        let refresh = decoded.refresh_token ?? previousRefreshToken ?? ""
        return OAuthToken(accessToken: decoded.access_token, refreshToken: refresh, expiresIn: decoded.expires_in)
    }

    private static func formURLEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
