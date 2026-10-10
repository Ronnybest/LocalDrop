import os

/// Log categories mirror the areas listed in the project logging requirements.
/// Never log file contents, keys, shared secrets or pairing codes.
nonisolated enum Log {
    private static let subsystem = "com.zepponapps.localdrop.mac"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let handshake = Logger(subsystem: subsystem, category: "handshake")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let crypto = Logger(subsystem: subsystem, category: "crypto")
}
