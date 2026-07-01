import Foundation

/// Configuration for the team-vault client.
///
/// In DEBUG builds we talk to the local Vault API (`SarvTerminalVault`) so the
/// whole flow can be exercised against `docker compose up` on localhost. The
/// release endpoint is a placeholder until the hosted service ships.
enum VaultConfig {
    static var baseURL: URL {
        #if DEBUG
        return URL(string: "http://localhost:4500")!
        #else
        return URL(string: "https://vault.sarv.com")!
        #endif
    }

    /// Where "Login with Sarv" sends the browser. In DEBUG this is the local
    /// customer console login; in release it'll be the hosted Sarv login. The
    /// page is expected to (eventually) redirect back via the app URL scheme,
    /// or show an auth token the user can paste manually.
    static var loginURL: URL {
        #if DEBUG
        return URL(string: "http://localhost:4520/login")!
        #else
        return URL(string: "https://vault.sarv.com/login")!
        #endif
    }

    /// Custom URL scheme the browser redirect uses for automatic sign-in
    /// (`sarvterminal://auth?token=…`). Registered in Info.plist.
    static let urlScheme = "sarvterminal"

    /// Whether the in-app dev-login (email-only) path is available. Mirrors the
    /// API's `AUTH_DEV_BYPASS`, which is on in local/dev and off in prod.
    static var devLoginEnabled: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
