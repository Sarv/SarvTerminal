import Foundation

/// True if we appear to be running in Xcode.
func isRunningInXcode() -> Bool {
    ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
}

/// True if the app was launched as an XCTest host (`xcodebuild test`).
///
/// Two things must be suppressed in that case. XCTest waits for the app to
/// finish launching and call back before it runs anything, so a blocking modal
/// at launch makes the runner fail with "The test runner timed out while
/// preparing to run tests". And the test host is built with the SAME debug
/// bundle id as the dev app, so it reads and writes the dev app's state — a
/// stray dialog from it lands on top of the real dev app, and anything it
/// saves overwrites the developer's live session.
func isRunningXCTest() -> Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
