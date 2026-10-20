import os
import CullerKit

/// Unified logging (Console.app: subsystem com.byairu.photoculler).
nonisolated enum Log {
    static let session = Logger(subsystem: AppConstants.bundleID, category: "session")
    static let writes = Logger(subsystem: AppConstants.bundleID, category: "writes")
    static let files = Logger(subsystem: AppConstants.bundleID, category: "files")
}
