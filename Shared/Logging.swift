import OSLog

/// Centralised os.Logger instances. Subsystem matches the bundle prefix.
enum Log {
    private static let subsystem = "com.accdrive"

    static let aps = Logger(subsystem: subsystem, category: "APSClient")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let fileProvider = Logger(subsystem: subsystem, category: "FileProvider")
    static let app = Logger(subsystem: subsystem, category: "App")
}
