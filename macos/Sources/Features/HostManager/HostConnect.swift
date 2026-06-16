import Foundation
import AppKit

/// Open a new embedded terminal tab in the Vaults window and run a shell
/// command in it (typically an `ssh …` invocation). The terminal lives inside
/// the single Vaults window — see `VaultsTabsModel`.
enum HostConnect {
    static func run(command: String, name: String = "Terminal") {
        VaultsTabsModel.shared.newTerminal(command: command, name: name)
    }
}
