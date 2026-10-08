import Foundation

/// Single source of truth for the product's name and identifiers.
/// Renaming the product means editing this file, `Support/Info.plist`
/// and `Scripts/build-app.sh` (names are kept in sync there).
public enum Brand {
    public static let name = "Still"
    /// Lowercase typographic wordmark.
    public static let wordmark = "still"
    public static let bundleID = "app.still.macos"
    public static let logSubsystem = bundleID
    /// Name of the privileged rule file inside /etc/sudoers.d (no dots allowed).
    public static let sudoersFileName = "still"
}
