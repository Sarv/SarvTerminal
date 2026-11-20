import Foundation
import Testing
@testable import Ghostty

struct SSHSessionMarkerTests {
    @Test func addsTheLoggedInHookToAnSSHCommand() {
        let command = SSHSessionMarker.command("ssh -p 2222 test@localhost", markerPath: "/tmp/sarv-ssh-1.ready")
        #expect(command == "ssh -o PermitLocalCommand=yes -o 'LocalCommand=/usr/bin/touch /tmp/sarv-ssh-1.ready' -p 2222 test@localhost")
    }

    /// ssh expands %-tokens in LocalCommand, so a literal % must be doubled.
    @Test func escapesPercentSigns() {
        let command = SSHSessionMarker.command("ssh host", markerPath: "/tmp/a%b.ready")
        #expect(command.contains("/usr/bin/touch /tmp/a%%b.ready"))
    }

    @Test func quotesPathsWithSpaces() {
        let command = SSHSessionMarker.command("ssh host", markerPath: "/tmp/my dir/m.ready")
        #expect(command.contains(#"'LocalCommand=/usr/bin/touch '\''/tmp/my dir/m.ready'\'''"#))
    }

    @Test func leavesOtherCommandsAlone() {
        #expect(SSHSessionMarker.command("mosh host", markerPath: "/tmp/m") == "mosh host")
    }

    @Test func makesAUniquePathInTheDirectory() {
        let id = UUID()
        #expect(SSHSessionMarker.makePath(directory: "/tmp", id: id) == "/tmp/sarv-ssh-\(id.uuidString).ready")
        #expect(SSHSessionMarker.makePath() != SSHSessionMarker.makePath())
    }
}
