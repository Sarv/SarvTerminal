import Foundation
import Testing
@testable import Ghostty

private func savedHost(_ hostname: String, user: String, port: Int = 22,
                       password: String = "", jump: String = "") -> SavedHost {
    var host = SavedHost.blank(hostname: hostname)
    host.username = user
    host.port = port
    host.password = password
    host.proxyJump = jump
    return host
}

@Suite
struct SSHPromptTests {
    @Test func readsHostKeyQuestionWithHostAndFingerprint() {
        let text = """
        The authenticity of host '[localhost]:2222 ([127.0.0.1]:2222)' can't be established.
        ED25519 key fingerprint is SHA256:abc123.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        #expect(SSHPrompt.parse(text)
            == .hostKey(host: "[localhost]:2222", detail: "ED25519 key fingerprint:\nSHA256:abc123."))
    }

    @Test func readsBothPasswordPromptStyles() {
        #expect(SSHPrompt.parse("ankur@10.0.41.98's password: ") == .password(user: "ankur", host: "10.0.41.98"))
        #expect(SSHPrompt.parse("(amit@ec2.example.com) Password:")
            == .password(user: "amit", host: "ec2.example.com"))
        #expect(SSHPrompt.parse("a@b@host's password:") == .password(user: "a@b", host: "host"))
        #expect(SSHPrompt.parse("Enter passphrase for key '/k/id':") == .other("Enter passphrase for key '/k/id':"))
    }

    @Test func credentialMatchesHostCaseInsensitivelyAndAnyUserWhenUnset() {
        let credentials = [SSHCredential(user: "", host: "Bastion", password: "b"),
                           SSHCredential(user: "ankur", host: "10.0.41.98", password: "t")]
        #expect(SSHCredential.answer(for: .password(user: "amit", host: "bastion"), from: credentials) == "b")
        #expect(SSHCredential.answer(for: .password(user: "ankur", host: "10.0.41.98"), from: credentials) == "t")
        #expect(SSHCredential.answer(for: .password(user: "root", host: "10.0.41.98"), from: credentials) == nil)
        #expect(SSHCredential.answer(for: .other("x"), from: credentials) == nil)
    }

    @Test func parsesJumpSpecLikeSsh() {
        #expect(SSHJump.hops("amit@ec2.example.com") == [.init(user: "amit", host: "ec2.example.com", port: 22)])
        #expect(SSHJump.hops("ssh://a@b:2200, c@[fe80::1]:23,plain") == [
            .init(user: "a", host: "b", port: 2200),
            .init(user: "c", host: "fe80::1", port: 23),
            .init(user: "", host: "plain", port: 22),
        ])
        #expect(SSHJump.hops("").isEmpty)
    }

    @Test func credentialsIncludeTargetAndSavedJumpHosts() {
        let bastion = savedHost("ec2.example.com", user: "amit", password: "jump-pw")
        let other = savedHost("ec2.example.com", user: "amit", port: 2200, password: "wrong-port")
        let target = savedHost("10.0.41.98", user: "ankur", password: "target-pw", jump: "amit@ec2.example.com")
        #expect(SSHJump.credentials(for: target, savedHosts: [other, bastion]) == [
            SSHCredential(user: "ankur", host: "10.0.41.98", password: "target-pw"),
            SSHCredential(user: "amit", host: "ec2.example.com", password: "jump-pw"),
        ])
    }

    @Test func backgroundArgsCarryJumpPolicyAndTimeout() {
        let target = savedHost("10.0.41.98", user: "ankur", jump: "amit@ec2.example.com")
        let args = SSHBackgroundArgs.connection(for: target)
        #expect(args.contains("-J") && args.contains("amit@ec2.example.com"))
        #expect(args.contains("ConnectTimeout=10"))
        #expect(args.contains("StrictHostKeyChecking=\(target.strictHostKeyChecking.rawValue)"))
    }

    @Test func failureReasonSkipsNoiseLines() {
        let stderr = "Authenticated to bastion (via proxy) using \"password\".\nchannel 0: open failed\n"
            + "Warning: Permanently added 'x' (ED25519) to the list of known hosts.\n"
        #expect(SSHBackgroundArgs.failureReason(stderr: stderr, status: 255) == "channel 0: open failed")
    }
}

@Suite
struct PortForwardPlanTests {
    private func forward(_ kind: PortForward.Kind) -> PortForward {
        var forward = PortForward.blank()
        forward.kind = kind
        forward.listenPort = 18500
        forward.destinationHost = "127.0.0.1"
        forward.destinationPort = 18500
        return forward
    }

    @Test func tunnelThroughJumpHostMatchesTheHandWrittenCommand() {
        let target = savedHost("10.0.41.98", user: "ankur", jump: "amit@ec2.example.com")
        let args = PortForwardPlan.arguments(for: forward(.local), host: target)
        #expect(args.first == "-N" && args.last == "ankur@10.0.41.98")
        #expect(args.contains("ExitOnForwardFailure=yes") && args.contains("LogLevel=VERBOSE"))
        let jump = args.firstIndex(of: "-J").map { args[$0 + 1] }
        #expect(jump == "amit@ec2.example.com")
        let spec = args.firstIndex(of: "-L").map { args[$0 + 1] }
        #expect(spec == "127.0.0.1:18500:127.0.0.1:18500")
    }

    @Test func forwardArgsPerKind() {
        #expect(PortForwardPlan.forwardArgs(forward(.remote)) == ["-R", "127.0.0.1:18500:127.0.0.1:18500"])
        #expect(PortForwardPlan.forwardArgs(forward(.dynamic)) == ["-D", "127.0.0.1:18500"])
    }

    @Test func detectsLoginAndExplainsBusyPort() {
        #expect(PortForwardPlan.hasAuthenticated("debug\nAuthenticated to 10.0.41.98 (via proxy) using \"password\".\n"))
        #expect(!PortForwardPlan.hasAuthenticated("Connection refused"))
        let busy = "bind [127.0.0.1]:18500: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen\n"
        #expect(PortForwardPlan.failureReason(stderr: busy, status: 255, forward: forward(.local))
            .hasPrefix("Port 18500 is already in use on this Mac"))
        #expect(PortForwardPlan.failureReason(stderr: busy, status: 255, forward: forward(.remote))
            == "Port 18500 is already in use on the server.")
    }

    @Test func localAddressOnlyForLocalEnds() {
        #expect(PortForwardPlan.localAddress(for: forward(.local)) == "127.0.0.1:18500")
        #expect(PortForwardPlan.localAddress(for: forward(.dynamic)) == "127.0.0.1:18500")
        #expect(PortForwardPlan.localAddress(for: forward(.remote)) == nil)
    }
}
