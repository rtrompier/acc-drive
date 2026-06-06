import AppKit
import AuthenticationServices

/// Drives the interactive 3-legged OAuth login via ASWebAuthenticationSession.
@MainActor
final class AuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthManager()

    enum AuthError: Error {
        case cannotStart
        case noAuthorizationCode
    }

    private var session: ASWebAuthenticationSession?

    /// Opens the browser login, exchanges the code, and stores the token.
    func signIn() async throws {
        let state = UUID().uuidString
        let authURL = APSAuth.authorizationURL(state: state)
        let scheme = AppConfig.shared.callbackScheme

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cannotStart)
                }
            }
            session.presentationContextProvider = self
            // Ephemeral: don't reuse the browser's Autodesk cookies, so each
            // sign-in prompts for credentials and the user can pick the account
            // (otherwise it silently re-authenticates as whoever is logged into
            // Autodesk in the browser).
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() {
                continuation.resume(throwing: AuthError.cannotStart)
            }
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw AuthError.noAuthorizationCode
        }

        let token = try await APSAuth.exchangeCode(code)
        TokenStore.save(token)
        Log.auth.info("Signed in; token stored")
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            return window
        }
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }
}
