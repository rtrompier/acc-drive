import FileProvider

/// Maps internal errors to the appropriate `NSFileProviderError`.
func fileProviderError(_ error: Error) -> Error {
    if let aps = error as? APSClient.APSError {
        switch aps {
        case .notAuthenticated:
            return NSFileProviderError(.notAuthenticated)
        case .notDownloadable, .invalidResponse, .server:
            // Never map a transient/download failure to .noSuchItem — that tells
            // the system the item was deleted and Finder removes it from the list.
            return NSFileProviderError(.serverUnreachable)
        case .notAuthorizedForAccount(let detail):
            return NSError(domain: "com.accdrive", code: 403, userInfo: [
                NSLocalizedDescriptionKey: "AccDrive isn’t authorized for this Autodesk account.",
                NSLocalizedFailureReasonErrorKey: detail,
                NSLocalizedRecoverySuggestionErrorKey:
                    "Ask an account admin to authorize the app in ACC → Account Admin → Settings → Custom Integrations.",
            ])
        }
    }
    if error is TokenManager.TokenError {
        return NSFileProviderError(.notAuthenticated)
    }
    return NSFileProviderError(.serverUnreachable)
}

/// Error returned for unsupported write operations (the drive is read-only).
var readOnlyError: Error {
    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
        NSLocalizedDescriptionKey: "Autodesk Construction Cloud is mounted read-only.",
    ])
}
