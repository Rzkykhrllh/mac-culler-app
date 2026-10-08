import Foundation

/// Single source of truth for every user-visible name and identifier.
/// Renaming the app is a change in this file (plus `project.yml` for the bundle ID / product name).
public enum AppConstants {
    /// User-visible application name.
    public static let appName = "PhotoCuller"
    /// Bundle identifier. Must match `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`.
    public static let bundleID = "com.byairu.photoculler"

    /// XMP namespace for fields this app owns that have no standard equivalent (flag, note).
    /// NOTE: finalize before real-world use — values written under this URI end up in users' files.
    public static let xmpNamespaceURI = "https://byairu.com/ns/culler/1.0/"
    public static let xmpNamespacePrefix = "culler"

    /// Extended attribute holding the compact JSON metadata backup.
    public static var xattrName: String { "\(bundleID).meta" }

    /// Directory names used under Caches / Application Support.
    public static var cacheDirectoryName: String { bundleID }
    public static var supportDirectoryName: String { bundleID }

    public static let operationLogFileName = "operations.jsonl"
    public static let indexFileName = "index.sqlite"
}
