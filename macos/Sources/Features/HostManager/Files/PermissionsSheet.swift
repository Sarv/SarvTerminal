import SwiftUI

/// Edit POSIX permissions two ways at once: a 3-digit octal field (e.g. `644`)
/// and a grid of Read / Write / Execute checkboxes for Owner / Group / Everyone.
/// Editing either side keeps the other in sync, so both people who think in
/// numbers and people who don't are covered.
struct PermissionsSheet: View {
    let fileName: String
    let isDirectory: Bool
    let onApply: (String) -> Void
    let onCancel: () -> Void

    /// The 9 permission bits, ordered owner r,w,x · group r,w,x · other r,w,x.
    @State private var bits: [Bool]
    /// The octal text the user can type directly (kept in sync with `bits`).
    @State private var octalText: String

    private let classes = ["Owner", "Group", "Everyone"]
    private let perms = ["Read", "Write", "Execute"]

    init(fileName: String, isDirectory: Bool, octal: String,
         onApply: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.isDirectory = isDirectory
        self.onApply = onApply
        self.onCancel = onCancel
        let parsed = Self.bits(fromOctal: octal)
        _bits = State(initialValue: parsed)
        _octalText = State(initialValue: Self.octal(fromBits: parsed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            checkboxGrid
            Divider()
            octalRow
            footer
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isDirectory ? "folder" : "doc")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions").font(.headline)
                Text(fileName).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    private var checkboxGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                ForEach(perms, id: \.self) { p in
                    Text(p).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .gridColumnAlignment(.center)
                }
            }
            ForEach(Array(classes.enumerated()), id: \.offset) { classIndex, name in
                GridRow {
                    Text(name).font(.callout)
                    ForEach(0..<3, id: \.self) { permIndex in
                        Toggle("", isOn: binding(classIndex: classIndex, permIndex: permIndex))
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                    }
                }
            }
        }
    }

    private var octalRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Octal").font(.caption).foregroundStyle(.secondary)
                TextField("755", text: $octalText)
                    .frame(width: 70)
                    .onChange(of: octalText) { newValue in
                        // Accept only octal digits (0–7), max 3 — so the boxes
                        // can always reflect what's typed.
                        let cleaned = String(newValue.filter { ("0"..."7").contains($0) }.prefix(3))
                        if cleaned != newValue { octalText = cleaned; return }
                        if cleaned.count == 3 { bits = Self.bits(fromOctal: cleaned) }
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Symbolic").font(.caption).foregroundStyle(.secondary)
                Text(Self.symbolic(fromBits: bits))
                    .font(.system(.callout, design: .monospaced))
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Apply") { onApply(Self.octal(fromBits: bits)) }
                .keyboardShortcut(.defaultAction)
                .disabled(octalText.count != 3)
        }
    }

    // MARK: - Binding

    /// A binding for one checkbox that flips the matching bit and re-syncs the
    /// octal field, so both representations always agree.
    private func binding(classIndex: Int, permIndex: Int) -> Binding<Bool> {
        let i = classIndex * 3 + permIndex
        return Binding(
            get: { bits[i] },
            set: { bits[i] = $0; octalText = Self.octal(fromBits: bits) }
        )
    }

    // MARK: - Conversions

    /// "644" → 9 bits (invalid input yields all-false).
    static func bits(fromOctal octal: String) -> [Bool] {
        var b = Array(repeating: false, count: 9)
        let digits = Array(octal.filter(\.isNumber).prefix(3))
        guard digits.count == 3 else { return b }
        for (c, ch) in digits.enumerated() {
            guard let v = Int(String(ch)), (0...7).contains(v) else { return Array(repeating: false, count: 9) }
            b[c * 3] = v & 4 != 0
            b[c * 3 + 1] = v & 2 != 0
            b[c * 3 + 2] = v & 1 != 0
        }
        return b
    }

    /// 9 bits → "644".
    static func octal(fromBits b: [Bool]) -> String {
        (0..<3).map { c -> String in
            var v = 0
            if b[c * 3] { v += 4 }
            if b[c * 3 + 1] { v += 2 }
            if b[c * 3 + 2] { v += 1 }
            return "\(v)"
        }.joined()
    }

    /// 9 bits → "rwxr-xr-x".
    static func symbolic(fromBits b: [Bool]) -> String {
        let letters = ["r", "w", "x"]
        return (0..<9).map { i in b[i] ? letters[i % 3] : "-" }.joined()
    }
}
