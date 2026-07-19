import SwiftUI

/// Drives the "explain / fix a failed command" flow. A non-zero exit (OSC 133
/// command-finished) records a scrollback snapshot; the user then asks the
/// configured LLM to explain it. Single source of truth for the banner UI.
@MainActor
final class AIAssistModel: ObservableObject {
    static let shared = AIAssistModel()

    struct Failure {
        let exitCode: Int
        let capturedText: String
        let pwd: String?
    }

    enum Phase: Equatable {
        case idle
        case offer
        case loading
        case result(String)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var failure: Failure?
    /// The first fenced code block from the last result — the runnable "fix".
    private(set) var suggestedCommand: String?

    private var task: Task<Void, Never>?

    /// From the command_finished hook (non-zero exit). Snapshots the output now
    /// because scrollback keeps changing after the command returns.
    func recordFailure(exitCode: Int, capturedText: String, pwd: String?) {
        guard AIConfigStore.shared.enabled,
              AIConfigStore.shared.currentSettings != nil else { return }
        task?.cancel()
        task = nil
        suggestedCommand = nil
        failure = Failure(exitCode: exitCode, capturedText: capturedText, pwd: pwd)
        withAnimation(.easeInOut(duration: 0.18)) { phase = .offer }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        failure = nil
        suggestedCommand = nil
        withAnimation(.easeInOut(duration: 0.18)) { phase = .idle }
    }

    func explain() {
        guard let failure else { return }
        guard let settings = AIConfigStore.shared.currentSettings else {
            phase = .error("Configure an AI provider in Settings → AI first.")
            return
        }
        let client = settings.makeClient()
        let request = Self.buildRequest(for: failure)
        withAnimation(.easeInOut(duration: 0.18)) { phase = .loading }
        task = Task { [weak self] in
            do {
                let text = try await client.complete(request)
                if Task.isCancelled { return }
                self?.suggestedCommand = Self.firstCodeBlock(in: text)
                withAnimation(.easeInOut(duration: 0.18)) { self?.phase = .result(text) }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                withAnimation(.easeInOut(duration: 0.18)) { self?.phase = .error(msg) }
            }
        }
    }

    // MARK: - Prompt

    private static func buildRequest(for failure: Failure) -> AICompletionRequest {
        let tail = failure.capturedText.aiTailLines(120)
        var context = ""
        if let pwd = failure.pwd, !pwd.isEmpty { context += "Working directory: \(pwd)\n" }
        context += "The last command exited with code \(failure.exitCode).\n\n"
        context += "Recent terminal output:\n\n```\n\(tail)\n```"

        let system = """
        You are a terminal assistant embedded in a macOS terminal app. A shell command \
        just failed. From the recent terminal output, work out which command failed and \
        why, then reply with:

        1. One or two sentences explaining what went wrong.
        2. A concrete fix as the exact command(s) to run, in a single fenced code block.

        Be concise. If the cause is ambiguous, give the most likely fix and note the \
        alternative in one line. Do not invent output or errors you cannot see.
        """
        return AICompletionRequest(
            system: system,
            messages: [AIMessage(role: .user, content: context)],
            maxTokens: 700
        )
    }

    /// Pull the first fenced ``` code block out of a markdown reply.
    private static func firstCodeBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // Skip an optional language tag on the opening fence line.
        var start = open.upperBound
        if let nl = text[start...].firstIndex(of: "\n") {
            start = text.index(after: nl)
        }
        guard let close = text.range(of: "```", range: start..<text.endIndex) else { return nil }
        let body = text[start..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

extension String {
    /// The last `n` lines, for trimming scrollback to a sane token budget.
    func aiTailLines(_ n: Int) -> String {
        let lines = split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > n else { return self }
        return lines.suffix(n).joined(separator: "\n")
    }
}

/// Floating card at the bottom of the terminal content. Offers to explain the
/// last failed command, then shows the explanation + a runnable fix.
struct AIAssistBanner: View {
    @ObservedObject private var model = AIAssistModel.shared

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                EmptyView()
            default:
                card
                    .frame(maxWidth: 540)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(true)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.phase)
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .offer:   offerBody
            case .loading: loadingBody
            case .result(let text): resultBody(text)
            case .error(let msg): errorBody(msg)
            case .idle: EmptyView()
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    // MARK: - Phases

    private var offerBody: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Command failed").font(.system(size: 12, weight: .semibold))
                if let code = model.failure?.exitCode {
                    Text("Exited with code \(code)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { model.explain() } label: {
                Label("Explain with AI", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            closeButton
        }
    }

    private var loadingBody: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Analyzing the failure…").font(.system(size: 12))
            Spacer(minLength: 8)
            Button("Cancel") { model.dismiss() }
                .buttonStyle(.plain).controlSize(.small)
                .foregroundStyle(.secondary)
        }
    }

    private func resultBody(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI suggestion").font(.system(size: 12, weight: .semibold))
                Spacer()
                closeButton
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)

            HStack(spacing: 8) {
                if let cmd = model.suggestedCommand {
                    Button {
                        _ = VaultsTabsModel.shared.pasteToTargetTerminal(cmd)
                    } label: {
                        Label("Paste fix", systemImage: "arrow.down.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .hoverTip("Paste the suggested command into the terminal (won't run it)")
                }
                Button {
                    let copy = model.suggestedCommand ?? text
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                } label: {
                    Label(model.suggestedCommand == nil ? "Copy" : "Copy command",
                          systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Button("Dismiss") { model.dismiss() }
                    .buttonStyle(.plain).controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorBody(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(msg).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            closeButton
        }
    }

    private var closeButton: some View {
        Button { model.dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTip("Dismiss")
    }
}
