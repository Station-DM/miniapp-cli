import Foundation

/// The CLI release version.
///
/// Keep this in sync with the public release tag (e.g. `v0.1.1`).
///
/// Note: Homebrew often builds from a source tarball without git metadata, so the
/// version must be embedded in the source at release time (similar to how `pod --version`
/// prints the CocoaPods gem version constant).
let miniAppCLIVersion = "v0.1.4"
