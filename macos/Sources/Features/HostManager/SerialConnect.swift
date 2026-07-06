import SwiftUI
import AppKit

/// Serial devices available on macOS. We use the `/dev/cu.*` ("call-up") device
/// files — the right ones to open for an outgoing serial console.
enum SerialPorts {
    /// macOS always exposes these stub devices even with nothing plugged in —
    /// they're not real consoles, so we hide them to keep the picker clean.
    private static let noise: Set<String> = ["cu.Bluetooth-Incoming-Port", "cu.debug-console"]

    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") && !noise.contains($0) }
            .map { "/dev/\($0)" }
            .sorted()
    }

    /// Friendly label for a device path (drops the `/dev/cu.` prefix).
    static func label(_ path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: "cu.", with: "")
    }
}

/// Ad-hoc serial console connect: pick a detected `/dev/cu.*` device + baud rate
/// and open a `screen` session (8-N-1, no flow control) in a new terminal tab.
/// Includes a "report an issue" affordance since serial behavior is
/// hardware-dependent and hard for us to test without the exact adapter.
struct SerialConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [String] = []
    @State private var selected: String = ""
    @State private var baud = 115200
    @State private var showReport = false

    /// Common baud rates, fastest-used first-ish; 115200 is the modern default.
    private let bauds = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Device").font(.caption).foregroundStyle(.secondaryText)
                    Spacer()
                    refreshButton
                }
                if devices.isEmpty {
                    Text("No serial devices found. Plug in a USB-serial adapter, then Refresh.")
                        .font(.callout).foregroundStyle(.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12)))
                } else {
                    Picker("", selection: $selected) {
                        ForEach(devices, id: \.self) { Text(SerialPorts.label($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            field("Baud rate") {
                Picker("", selection: $baud) {
                    ForEach(bauds, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .labelsHidden().frame(width: 160)
                Text("Framing 8-N-1, no flow control. Opens with the built-in `screen`.")
                    .font(.caption2).foregroundStyle(.tertiaryText)
            }

            Divider()
            reportLine

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
        .onAppear(perform: refresh)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cable.connector").font(.title2).foregroundStyle(.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Serial Console").font(.headline)
                Text("Connect to a device over a USB-serial adapter.")
                    .font(.subheadline).foregroundStyle(.secondaryText)
            }
            Spacer()
        }
    }

    private var refreshButton: some View {
        Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .buttonStyle(.borderless).controlSize(.small)
    }

    private var reportLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondaryText)
            Text("Serial support is new — if a device won't connect,")
                .font(.caption).foregroundStyle(.secondaryText)
            Button("report an issue") { showReport = true }
                .buttonStyle(.link).font(.caption)
                .popover(isPresented: $showReport, arrowEdge: .bottom) { reportPopover }
        }
    }

    private var reportPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Report a serial issue").font(.headline)
            Text("Please include the following so we can reproduce it:")
                .font(.callout).foregroundStyle(.secondaryText)
            VStack(alignment: .leading, spacing: 5) {
                Label("What happened — not listed / blank / garbled / error text", systemImage: "1.circle")
                Label("Adapter make & chipset — FTDI, CP210x, Prolific, vendor cable", systemImage: "2.circle")
                Label("The device path & baud you used", systemImage: "3.circle")
                Label("Output of  ls /dev/cu.*", systemImage: "4.circle")
                Label("Your macOS version", systemImage: "5.circle")
            }
            .font(.caption)
            Text("The button opens a GitHub issue pre-filled with these fields (device, baud and macOS are added automatically).")
                .font(.caption2).foregroundStyle(.tertiaryText).fixedSize(horizontal: false, vertical: true)
            Button {
                if let url = issueURL() { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open a GitHub issue", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 360)
    }

    private func field<Content: View>(_ label: String,
                                       @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondaryText)
            content()
        }
    }

    // MARK: - Actions

    private func refresh() {
        devices = SerialPorts.list()
        if selected.isEmpty || !devices.contains(selected) { selected = devices.first ?? "" }
    }

    private func connect() {
        guard !selected.isEmpty else { return }
        VaultsTabsModel.shared.newSerial(device: selected, baud: baud)
        dismiss()
    }

    /// Build a pre-filled GitHub issue URL with the bug-report template.
    private func issueURL() -> URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let app = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let body = """
        **What happened?**
        <e.g. device not listed / blank screen / garbled text / error message>

        **Adapter / cable**
        <make & chipset — FTDI, CP210x, Prolific, vendor console cable…>

        **Device & settings**
        - Device: \(selected.isEmpty ? "<none selected>" : selected)
        - Baud: \(baud)
        - Framing: 8-N-1

        **Environment**
        - macOS: \(os)
        - SarvTerminal: \(app)

        **`ls /dev/cu.*` output**

        ```
        <paste here>
        ```
        """
        var comps = URLComponents(string: "https://github.com/Sarv/SarvTerminal/issues/new")
        comps?.queryItems = [
            URLQueryItem(name: "title", value: "Serial: "),
            URLQueryItem(name: "labels", value: "serial"),
            URLQueryItem(name: "body", value: body),
        ]
        return comps?.url
    }
}
