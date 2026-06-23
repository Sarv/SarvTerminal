import SwiftUI

/// Dual-pane file manager (SFTP + local, server↔server). Each pane points at
/// Local or a saved host; "Copy to target directory" transfers the selection
/// into the OTHER pane's current folder. Replaces the old SFTP and SCP tabs.
/// Holds the two SFTP panes so their state (current folder, connected host,
/// listing) survives the dashboard being torn down when a terminal tab shows.
/// `SFTPView`'s own `@StateObject` panes used to reset on every re-mount.
/// Live progress for an in-flight transfer.
struct TransferState: Equatable {
    var fileName: String
    var total: Int64          // 0 = indeterminate (e.g. a directory)
    var transferred: Int64
    var bytesPerSecond: Double
    var direct: Bool          // true = server→server direct; false = via this Mac
}

@MainActor
final class SFTPSession: ObservableObject {
    static let shared = SFTPSession()
    let left = SFTPBrowserModel()
    let right = SFTPBrowserModel()

    /// Current transfer progress (nil when idle). Lives here so the overlay
    /// survives the dashboard being torn down for a terminal tab.
    @Published var transfer: TransferState?
    /// The in-flight transfer task, so it can be cancelled from the overlay.
    var transferTask: Task<Void, Never>?

    func cancelTransfer() { transferTask?.cancel() }

    private var started = false
    private init() {}

    /// Connect both panes to Local — once, ever. No-op after the first call so
    /// returning to SFTP keeps wherever the user navigated.
    func startIfNeeded() {
        guard !started else { return }
        started = true
        left.connect(to: .local)
        right.connect(to: .local)
    }
}

struct SFTPView: View {
    @ObservedObject private var left = SFTPSession.shared.left
    @ObservedObject private var right = SFTPSession.shared.right
    @ObservedObject private var session = SFTPSession.shared

    enum Side: String, Identifiable { case left, right; var id: String { rawValue } }

    // Dialog state (centralized so both panes share identical behavior).
    @State private var hostPickerSide: Side?
    @State private var newFolderSide: Side?
    @State private var newFolderName = ""
    @State private var renameTarget: (side: Side, item: FileItem)?
    @State private var renameText = ""
    @State private var permTarget: (side: Side, item: FileItem)?
    @State private var conflict: ConflictRequest?
    @State private var viewer: FileViewerModel?
    @State private var pendingDelete: (side: Side, item: FileItem)?

    struct ConflictRequest: Identifiable {
        let id = UUID()
        let item: FileItem
        let fromSide: Side
    }

    var body: some View {
        HStack(spacing: 0) {
            FilePaneView(model: left) { handle($0, on: .left) }
            Divider()
            FilePaneView(model: right) { handle($0, on: .right) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { SFTPSession.shared.startIfNeeded() }
        .sheet(item: $hostPickerSide) { side in
            FileHostChooser { location in
                model(side).connect(to: location)
                hostPickerSide = nil
            } onCancel: { hostPickerSide = nil }
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderSide != nil }, set: { if !$0 { newFolderSide = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderSide = nil }
            Button("Create") {
                if let s = newFolderSide, !newFolderName.isEmpty { Task { await model(s).newFolder(named: newFolderName) } }
                newFolderSide = nil; newFolderName = ""
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("New name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let t = renameTarget, !renameText.isEmpty { Task { await model(t.side).rename(t.item, to: renameText) } }
                renameTarget = nil
            }
        }
        .sheet(isPresented: Binding(get: { permTarget != nil }, set: { if !$0 { permTarget = nil } })) {
            if let t = permTarget {
                PermissionsSheet(
                    fileName: t.item.name,
                    isDirectory: t.item.isDirectory,
                    octal: octalGuess(t.item),
                    onApply: { octal in
                        Task { await model(t.side).setPermissions(t.item, octal: octal) }
                        permTarget = nil
                    },
                    onCancel: { permTarget = nil })
            }
        }
        .alert("Delete “\(pendingDelete?.item.name ?? "")”?",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let d = pendingDelete { Task { await model(d.side).delete(d.item) } }
                pendingDelete = nil
            }
        } message: { Text("This can't be undone.") }
        .overlay {
            if let c = conflict { ConflictDialog(name: c.item.name) { resolve(c, $0) } }
        }
        .overlay {
            if let t = session.transfer { progressOverlay(t) }
        }
        .overlay {
            if let v = viewer {
                FileViewerView(model: v, onClose: { viewer = nil })
                    .transition(.move(edge: .trailing))
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewer == nil)
    }

    private func progressOverlay(_ t: TransferState) -> some View {
        let fraction = t.total > 0 ? min(1, Double(t.transferred) / Double(t.total)) : 0
        return ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: t.direct ? "arrow.left.arrow.right" : "externaldrive.connected.to.line.below")
                        .foregroundStyle(t.direct ? .green : .blue)
                    Text(t.fileName).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(t.direct ? "Server → Server" : "Via this Mac")
                        .font(.caption).foregroundStyle(t.direct ? .green : .secondary)
                }
                if t.total > 0 {
                    ProgressView(value: fraction)
                    HStack {
                        Text("\(byteString(t.transferred)) / \(byteString(t.total)) · \(Int(fraction * 100))%")
                        Spacer()
                        Text(t.bytesPerSecond > 0 ? "\(byteString(Int64(t.bytesPerSecond)))/s" : "—")
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("Transferring…").font(.caption).foregroundStyle(.secondary)
                }
                if !t.direct {
                    Label("Servers can't connect directly — relaying through this Mac (uses your bandwidth).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { session.cancelTransfer() }
                        .controlSize(.small)
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    // MARK: - Coordination

    private func model(_ side: Side) -> SFTPBrowserModel { side == .left ? left : right }
    private func otherSide(_ side: Side) -> Side { side == .left ? .right : .left }

    private func handle(_ action: FilePaneAction, on side: Side) {
        let m = model(side)
        switch action {
        case .chooseHost: hostPickerSide = side
        case .open(let item):
            if item.isDirectory { m.open(item) }
            else { viewer = FileViewerModel(item: item, backend: m.backend) }
        case .goUp: m.goUp()
        case .navigate(let p): Task { await m.load(p) }
        case .refresh: Task { await m.reload() }
        case .newFolder: newFolderName = ""; newFolderSide = side
        case .rename(let item): renameText = item.name; renameTarget = (side, item)
        case .delete(let item):
            if SFTPSettings.shared.confirmDelete { pendingDelete = (side, item) }
            else { Task { await m.delete(item) } }
        case .editPermissions(let item): permTarget = (side, item)
        case .copyToTarget(let item): startCopy(item, from: side)
        }
    }

    private func startCopy(_ item: FileItem, from side: Side) {
        let dest = model(otherSide(side))
        Task {
            if await dest.exists(name: item.name) {
                conflict = ConflictRequest(item: item, fromSide: side)
            } else {
                beginTransfer(item, from: side, resolution: .replace) // no conflict → straight copy
            }
        }
    }

    private func resolve(_ request: ConflictRequest, _ resolution: ConflictResolution) {
        conflict = nil
        guard resolution != .stop, resolution != .skip else { return }
        beginTransfer(request.item, from: request.fromSide, resolution: resolution)
    }

    /// Start a transfer as a cancellable task tracked by the session.
    private func beginTransfer(_ item: FileItem, from side: Side, resolution: ConflictResolution) {
        let task = Task { await performCopy(item, from: side, resolution: resolution) }
        session.transferTask = task
        Task { await task.value; session.transferTask = nil }
    }

    private func performCopy(_ item: FileItem, from side: Side, resolution: ConflictResolution) async {
        let source = model(side), dest = model(otherSide(side))
        let started = Date()
        // Server → server. We have both hosts' details, so never ask — try the
        // direct path when the destination is key-based, and otherwise (or if the
        // servers can't reach each other) relay through this Mac automatically.
        if source.backend is RemoteFileBackend, dest.backend is RemoteFileBackend {
            // Always try a direct A→B transfer first (key → agent forwarding,
            // password → saved password via one-shot askpass on A). Only relay
            // through this Mac if the servers can't reach each other.
            var ok = await runRemoteTransfer(item, from: side, resolution: resolution, direct: true)
            if !ok, !Task.isCancelled {
                ok = await runRemoteTransfer(item, from: side, resolution: resolution, direct: false)
            }
            notifyTransferOutcome(item: item, succeeded: ok, reason: dest.error, started: started)
            return
        }
        // Local ⇄ remote (or local ⇄ local): the existing path, with progress.
        var failure: String?
        await withProgress(item: item, destBackend: dest.backend, destDir: dest.path,
                           resolution: resolution, direct: false) {
            try await FileTransfer.copy(item: item, from: source.backend, to: dest.backend,
                                        destDir: dest.path, resolution: resolution)
        } onFinish: { await dest.reload() } onError: { dest.error = $0; failure = $0 }
        notifyTransferOutcome(item: item, succeeded: failure == nil, reason: failure, started: started)
    }

    /// Post a finished/failed notification for one completed transfer. Quick
    /// transfers (< 3s) only notify on failure, to avoid noise; a user-cancelled
    /// transfer doesn't notify at all.
    private func notifyTransferOutcome(item: FileItem, succeeded: Bool, reason: String?, started: Date) {
        if Task.isCancelled { return }
        let elapsed = Date().timeIntervalSince(started)
        Task { @MainActor in
            if succeeded {
                if elapsed >= 3 {
                    SarvNotifications.shared.notify(.sftpFinished(file: item.name, host: nil))
                }
            } else {
                SarvNotifications.shared.notify(
                    .sftpFailed(file: item.name, host: nil, reason: reason ?? "Transfer failed"))
            }
        }
    }

    /// Run a server→server transfer. Returns false on failure (so the caller can
    /// fall back from direct → relay). A relay failure is surfaced to the pane;
    /// a direct failure is silent (we just relay instead).
    @discardableResult
    private func runRemoteTransfer(_ item: FileItem, from side: Side, resolution: ConflictResolution, direct: Bool) async -> Bool {
        guard let src = model(side).backend as? RemoteFileBackend,
              let dst = model(otherSide(side)).backend as? RemoteFileBackend else { return false }
        let dest = model(otherSide(side))
        var ok = true
        await withProgress(item: item, destBackend: dst, destDir: dest.path, resolution: resolution, direct: direct) {
            _ = try await FileTransfer.serverToServer(item: item, from: src, to: dst,
                                                      destDir: dest.path, resolution: resolution, direct: direct)
        } onFinish: { await dest.reload() } onError: { msg in
            ok = false
            if !direct { dest.error = msg }   // relay is the final attempt → surface it
        }
        return ok
    }

    /// Wrap a transfer with the progress overlay + a poller that watches the
    /// destination file's size against the known source size.
    private func withProgress(item: FileItem, destBackend: FileBackend, destDir: String,
                              resolution: ConflictResolution, direct: Bool,
                              _ op: @escaping () async throws -> Void,
                              onFinish: @escaping () async -> Void,
                              onError: @escaping (String) -> Void) async {
        let destPath = destBackend.join(destDir, FileTransfer.finalName(for: item, resolution: resolution))
        let total = item.isDirectory ? 0 : item.size
        session.transfer = TransferState(fileName: item.name, total: total, transferred: 0,
                                         bytesPerSecond: 0, direct: direct)
        let start = Date()
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { break }
                let size = await destBackend.fileSize(destPath) ?? session.transfer?.transferred ?? 0
                let elapsed = max(0.001, Date().timeIntervalSince(start))
                if var t = session.transfer {
                    t.transferred = size
                    t.bytesPerSecond = Double(size) / elapsed
                    session.transfer = t
                }
            }
        }
        do { try await op(); await onFinish() }
        catch {
            // A user cancel terminates the process (non-zero) — don't show it as an error.
            if !Task.isCancelled { onError((error as? FileOpError)?.message ?? error.localizedDescription) }
        }
        poller.cancel()
        session.transfer = nil
    }

    /// Best-effort octal default for the permissions dialog from "rwxr-xr-x".
    private func octalGuess(_ item: FileItem) -> String {
        guard let p = item.permissions, p.count == 9 else { return item.isDirectory ? "755" : "644" }
        let chars = Array(p)
        var digits = ""
        for chunk in stride(from: 0, to: 9, by: 3) {
            var v = 0
            if chars[chunk] == "r" { v += 4 }
            if chars[chunk + 1] == "w" { v += 2 }
            if chars[chunk + 2] == "x" { v += 1 }
            digits += "\(v)"
        }
        return digits
    }
}

/// Actions a pane reports up to the coordinator.
enum FilePaneAction {
    case chooseHost
    case open(FileItem)
    case goUp
    case navigate(String)
    case refresh
    case newFolder
    case rename(FileItem)
    case delete(FileItem)
    case editPermissions(FileItem)
    case copyToTarget(FileItem)
}
