import SwiftUI
import AppKit

// MARK: - Models

struct DockerContainer: Identifiable, Hashable {
    let id: String        // short container ID
    let name: String
    let image: String
    let status: String
}

struct K8sPod: Identifiable, Hashable {
    var id: String { "\(namespace)/\(name)" }
    let namespace: String
    let name: String
    let phase: String        // Running, Pending, CrashLoopBackOff, …
    let containers: [String]

    var isRunning: Bool { phase == "Running" }
}

// MARK: - Service (login-shell shell-out)

/// Lists Docker containers / Kubernetes pods and builds the `exec` command that
/// attaches an interactive shell. Commands run through the user's LOGIN shell so
/// `docker` / `kubectl` resolve on the same PATH they would in a normal terminal
/// (Docker Desktop and kubectl usually live in /usr/local/bin or Homebrew).
enum ContainerAttachService {
    /// Run `command` via `$SHELL -lc`, returning stdout, stderr, and exit code.
    static func run(_ command: String) async -> (out: String, err: String, code: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-lc", command]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ("", error.localizedDescription, -1))
                    return
                }
                // Read before waiting so a large output can't deadlock the pipe.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "",
                    process.terminationStatus
                ))
            }
        }
    }

    static func listDocker() async -> (items: [DockerContainer], error: String?) {
        let r = await run("docker ps --format '{{json .}}'")
        guard r.code == 0 else {
            return ([], cleanError(r.err, fallback: "Docker isn't available."))
        }
        var out: [DockerContainer] = []
        for line in r.out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["ID"] as? String, !id.isEmpty else { continue }
            out.append(DockerContainer(
                id: id,
                name: (obj["Names"] as? String) ?? id,
                image: (obj["Image"] as? String) ?? "",
                status: (obj["Status"] as? String) ?? ""
            ))
        }
        return (out, nil)
    }

    static func listPods() async -> (items: [K8sPod], error: String?) {
        let r = await run("kubectl get pods --all-namespaces -o json")
        guard r.code == 0 else {
            return ([], cleanError(r.err, fallback: "kubectl isn't available."))
        }
        guard let data = r.out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return ([], "Couldn't parse kubectl output.")
        }
        var pods: [K8sPod] = []
        for item in items {
            let meta = item["metadata"] as? [String: Any]
            let spec = item["spec"] as? [String: Any]
            let status = item["status"] as? [String: Any]
            guard let name = meta?["name"] as? String, !name.isEmpty else { continue }
            let containers = (spec?["containers"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            pods.append(K8sPod(
                namespace: (meta?["namespace"] as? String) ?? "default",
                name: name,
                phase: (status?["phase"] as? String) ?? "",
                containers: containers
            ))
        }
        return (pods, nil)
    }

    /// Absolute path of a CLI (docker/kubectl) as an interactive login shell
    /// would resolve it — needed because a directly-spawned process (Ghostty's
    /// `command`) doesn't inherit the Homebrew / /usr/local PATH.
    static func resolve(_ tool: String) async -> String? {
        let r = await run("command -v \(tool)")
        let path = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.code == 0 && !path.isEmpty) ? path : nil
    }

    /// `<binary> exec -it <name> sh` — a plain single-word shell so the whole
    /// command is space-separated words with no quoted arguments. Ghostty's
    /// `command` splits on whitespace and does NOT honor a quoted arg containing
    /// spaces, so a `sh -c '…'` wrapper gets shredded and never runs. `sh` exists
    /// in every image (including Alpine); to use bash, run it once inside.
    /// `binary` is `docker`, or its absolute path for a directly-spawned tab.
    static func dockerAttachCommand(binary: String, _ c: DockerContainer) -> String {
        "\(binary) exec -it \(c.name) sh"
    }

    /// `<binary> exec -it -n <ns> <pod> [-c container] -- sh`.
    static func k8sAttachCommand(binary: String, _ pod: K8sPod, container: String?) -> String {
        // Namespace / pod / container names are DNS-1123 safe (no quoting needed).
        var cmd = "\(binary) exec -it -n \(pod.namespace) \(pod.name)"
        if let container, !container.isEmpty { cmd += " -c \(container)" }
        cmd += " -- sh"
        return cmd
    }

    private static func cleanError(_ err: String, fallback: String) -> String {
        let lower = err.lowercased()
        if lower.contains("command not found") || lower.contains("no such file") {
            return fallback  // e.g. "Docker isn't available." / "kubectl isn't available."
        }
        if lower.contains("connection refused") || lower.contains("was refused")
            || lower.contains("couldn't get current server")
            || lower.contains("unable to connect")
            || lower.contains("cannot connect to the docker daemon") {
            return "Not reachable — is it running?"
        }
        // docker/kubectl are chatty on stderr (log-prefixed lines). Pick the last
        // line that reads like the actual error, else the last non-empty line.
        let lines = err.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let pick = lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? ""
        if pick.isEmpty { return fallback }
        return pick.count > 140 ? String(pick.prefix(140)) + "…" : pick
    }
}

// MARK: - Model

/// Backs the container-attach side panel. Lists Docker containers and K8s pods,
/// and opens an `exec` shell in a new terminal tab on click.
@MainActor
final class ContainerAttachModel: ObservableObject {
    static let shared = ContainerAttachModel()

    @Published private(set) var dockerContainers: [DockerContainer] = []
    @Published private(set) var pods: [K8sPod] = []
    @Published private(set) var dockerError: String?
    @Published private(set) var k8sError: String?
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false

    /// Absolute binary paths (login-shell PATH), used for directly-spawned tabs.
    private var dockerPath: String?
    private var kubectlPath: String?

    func refresh() {
        guard !loading else { return }
        loading = true
        Task { @MainActor in
            async let dockerResult = ContainerAttachService.listDocker()
            async let podResult = ContainerAttachService.listPods()
            async let dockerBin = ContainerAttachService.resolve("docker")
            async let kubectlBin = ContainerAttachService.resolve("kubectl")
            let (docker, k8s, dPath, kPath) = await (dockerResult, podResult, dockerBin, kubectlBin)

            dockerContainers = docker.items
            dockerError = docker.error
            pods = k8s.items
            k8sError = k8s.error
            dockerPath = dPath
            kubectlPath = kPath
            loading = false
            loadedOnce = true
        }
    }

    func attach(_ c: DockerContainer, target: AttachTarget) {
        // New tab spawns the process directly, so it needs the absolute path
        // (docker isn't on Ghostty's minimal spawn PATH). The current tab types
        // into an interactive shell that already has the full PATH.
        let binary = target == .newTab ? (dockerPath ?? "docker") : "docker"
        open(ContainerAttachService.dockerAttachCommand(binary: binary, c), name: c.name, target: target)
    }

    func attach(_ pod: K8sPod, container: String?, target: AttachTarget) {
        let binary = target == .newTab ? (kubectlPath ?? "kubectl") : "kubectl"
        open(ContainerAttachService.k8sAttachCommand(binary: binary, pod, container: container),
             name: pod.name, target: target)
    }

    /// Whether a "current tab" target exists right now (drives the menu item).
    var hasActiveTerminal: Bool { VaultsTabsModel.shared.hasActiveTerminal }

    private func open(_ command: String, name: String, target: AttachTarget) {
        switch target {
        case .newTab:
            _ = VaultsTabsModel.shared.newCommandTerminal(command: command, name: name)
        case .currentTab:
            _ = VaultsTabsModel.shared.runInTargetTerminal(command)
        }
    }
}

/// Where an attach shell opens.
enum AttachTarget { case newTab, currentTab }

// MARK: - Sidebar tab

/// Command-sidebar tab listing Docker containers and Kubernetes pods. Clicking a
/// row opens an interactive `exec` shell in a new terminal tab. Lives in the
/// shared command sidebar (alongside Snippets / History / Themes) so it doesn't
/// add another top-bar icon.
struct ContainersTab: View {
    @ObservedObject private var model = ContainerAttachModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dockerSection
                    k8sSection
                }
                .padding(.vertical, 12)
            }
        }
        .onAppear { if !model.loadedOnce { model.refresh() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Attach a shell").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button { model.refresh() } label: {
                if model.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.loading)
            .hoverTip("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Docker

    private var dockerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Docker", systemImage: "cube.box", count: model.dockerContainers.count)
            if let err = model.dockerError {
                emptyNote(err)
            } else if model.dockerContainers.isEmpty {
                emptyNote(model.loadedOnce ? "No running containers." : "Loading…")
            } else {
                ForEach(model.dockerContainers) { c in
                    row(title: c.name, subtitle: subtitle(c.image, c.status)) {
                        tabTargetButtons { model.attach(c, target: $0) }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Kubernetes

    private var k8sSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Kubernetes", systemImage: "helm", count: model.pods.count)
            if let err = model.k8sError {
                emptyNote(err)
            } else if model.pods.isEmpty {
                emptyNote(model.loadedOnce ? "No pods found." : "Loading…")
            } else {
                ForEach(model.pods) { pod in
                    if pod.containers.count > 1 {
                        row(title: pod.name,
                            subtitle: subtitle("\(pod.namespace) · \(pod.phase)",
                                               "\(pod.containers.count) containers")) {
                            ForEach(pod.containers, id: \.self) { name in
                                Menu(name) {
                                    tabTargetButtons { model.attach(pod, container: name, target: $0) }
                                }
                            }
                        }
                    } else {
                        row(title: pod.name, subtitle: subtitle(pod.namespace, pod.phase)) {
                            tabTargetButtons { model.attach(pod, container: pod.containers.first, target: $0) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Row + attach menu

    /// A non-clickable info row with an attach menu anchored on the terminal
    /// icon. Only the icon is interactive — clicking anywhere else does nothing
    /// (so a stray row click never spawns a tab).
    private func row<Menu: View>(title: String,
                                 subtitle: String,
                                 @ViewBuilder menu: () -> Menu) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            SwiftUI.Menu {
                menu()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverTip("Open a shell here")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .listRowHover()
    }

    /// The "new tab / current tab" choice shown in every attach menu.
    @ViewBuilder private func tabTargetButtons(_ action: @escaping (AttachTarget) -> Void) -> some View {
        Button {
            action(.newTab)
        } label: {
            Label("Open in new tab", systemImage: "plus.rectangle.on.rectangle")
        }
        Button {
            action(.currentTab)
        } label: {
            Label("Run in current tab", systemImage: "return")
        }
        .disabled(!model.hasActiveTerminal)
    }

    // MARK: Bits

    private func sectionHeader(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if count > 0 {
                Text("\(count)").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func subtitle(_ a: String, _ b: String) -> String {
        [a, b].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
