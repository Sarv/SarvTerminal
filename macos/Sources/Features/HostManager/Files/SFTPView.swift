import SwiftUI

/// Dual-pane file manager (SFTP + local, server↔server). Each pane points at
/// Local or a saved host; "Copy to target directory" transfers the selection
/// into the OTHER pane's current folder. Replaces the old SFTP and SCP tabs.
struct SFTPView: View {
    @StateObject private var left = SFTPBrowserModel()
    @StateObject private var right = SFTPBrowserModel()

    enum Side: String, Identifiable { case left, right; var id: String { rawValue } }

    // Dialog state (centralized so both panes share identical behavior).
    @State private var hostPickerSide: Side?
    @State private var newFolderSide: Side?
    @State private var newFolderName = ""
    @State private var renameTarget: (side: Side, item: FileItem)?
    @State private var renameText = ""
    @State private var permTarget: (side: Side, item: FileItem)?
    @State private var permText = ""
    @State private var conflict: ConflictRequest?
    @State private var isTransferring = false
    @State private var didInit = false
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
        .onAppear {
            guard !didInit else { return }
            didInit = true
            left.connect(to: .local)
            right.connect(to: .local)
        }
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
        .alert("Edit Permissions", isPresented: Binding(get: { permTarget != nil }, set: { if !$0 { permTarget = nil } })) {
            TextField("Octal (e.g. 755)", text: $permText)
            Button("Cancel", role: .cancel) { permTarget = nil }
            Button("Apply") {
                if let t = permTarget, !permText.isEmpty { Task { await model(t.side).setPermissions(t.item, octal: permText) } }
                permTarget = nil
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
            if isTransferring { transferOverlay }
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

    private var transferOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                Text("Copying…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        }
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
        case .editPermissions(let item): permText = octalGuess(item); permTarget = (side, item)
        case .copyToTarget(let item): startCopy(item, from: side)
        }
    }

    private func startCopy(_ item: FileItem, from side: Side) {
        let dest = model(otherSide(side))
        Task {
            if await dest.exists(name: item.name) {
                conflict = ConflictRequest(item: item, fromSide: side)
            } else {
                await performCopy(item, from: side, resolution: .replace) // no conflict → straight copy
            }
        }
    }

    private func resolve(_ request: ConflictRequest, _ resolution: ConflictResolution) {
        conflict = nil
        guard resolution != .stop, resolution != .skip else { return }
        Task { await performCopy(request.item, from: request.fromSide, resolution: resolution) }
    }

    private func performCopy(_ item: FileItem, from side: Side, resolution: ConflictResolution) async {
        let source = model(side), dest = model(otherSide(side))
        isTransferring = true
        do {
            try await FileTransfer.copy(item: item, from: source.backend, to: dest.backend,
                                        destDir: dest.path, resolution: resolution)
            await dest.reload()
        } catch {
            dest.error = (error as? FileOpError)?.message ?? error.localizedDescription
        }
        isTransferring = false
    }

    /// Best-effort octal default for the permissions dialog from "rwxr-xr-x".
    private func octalGuess(_ item: FileItem) -> String {
        guard let p = item.permissions, p.count == 9 else { return item.isDirectory ? "755" : "644" }
        var digits = ""
        for chunk in stride(from: 0, to: 9, by: 3) {
            let part = Array(p)[chunk..<chunk+3]
            var v = 0
            if part[0] == "r" { v += 4 }
            if part[1] == "w" { v += 2 }
            if part[2] == "x" { v += 1 }
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
