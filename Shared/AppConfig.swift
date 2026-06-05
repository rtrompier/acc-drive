import Foundation

/// Reads the APS credentials from the bundled `Config.plist`.
///
/// `Config.plist` is added as a resource to both the host app and the
/// extension, so `Bundle.main` resolves correctly in either process.
struct AppConfig {
    let clientId: String
    let clientSecret: String
    let redirectURI: String
    /// When true, the API layer returns canned demo data instead of calling APS.
    let mockMode: Bool

    static let shared = AppConfig.load()

    private static func load() -> AppConfig {
        guard let url = Bundle.main.url(forResource: "Config", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            fatalError("Config.plist is missing or invalid. Copy the template and fill in your APS credentials.")
        }

        let clientId = (dict["APS_CLIENT_ID"] as? String) ?? ""
        let clientSecret = (dict["APS_CLIENT_SECRET"] as? String) ?? ""
        let redirectURI = (dict["APS_REDIRECT_URI"] as? String) ?? "accdrive://oauth/callback"
        let mockMode = (dict["MOCK_MODE"] as? Bool) ?? false

        if !mockMode, clientId.isEmpty || clientId == "YOUR_APS_CLIENT_ID" {
            Log.app.error("Config.plist does not contain a real APS_CLIENT_ID.")
        }

        return AppConfig(clientId: clientId, clientSecret: clientSecret, redirectURI: redirectURI, mockMode: mockMode)
    }

    /// The URL scheme part of the redirect URI, used by ASWebAuthenticationSession.
    var callbackScheme: String {
        URLComponents(string: redirectURI)?.scheme ?? "accdrive"
    }
}
