import SwiftUI
import AppKit
import WebKit

/// Loads a file's text (local file, or a downloaded temp copy for remote) for
/// the viewer pane.
@MainActor
final class FileViewerModel: ObservableObject {
    let item: FileItem
    private let backend: FileBackend

    @Published var content: String = ""
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var error: String?
    @Published var renderMarkdown: Bool
    /// Resolved local URL (for "Reveal in Finder" / "Open in editor").
    @Published var localURL: URL?

    /// Content as last loaded/saved — drives the dirty (unsaved) indicator.
    private var savedContent = ""
    var isDirty: Bool { content != savedContent }
    private var autosaveWork: DispatchWorkItem?

    /// Max bytes we'll read into the viewer.
    private let maxBytes = 4 * 1024 * 1024

    var isMarkdown: Bool {
        let n = item.name.lowercased()
        return n.hasSuffix(".md") || n.hasSuffix(".markdown")
    }

    init(item: FileItem, backend: FileBackend) {
        self.item = item
        self.backend = backend
        self.renderMarkdown = item.name.lowercased().hasSuffix(".md") || item.name.lowercased().hasSuffix(".markdown")
    }

    func load() async {
        isLoading = true
        error = nil
        do {
            let url = try await backend.localCopy(of: item)
            localURL = url
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs?[.size] as? Int, size > maxBytes {
                error = "File is too large to preview (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                content = text
                savedContent = text
            } else {
                error = "Can't preview this file (binary or non-text)."
            }
        } catch {
            self.error = (error as? FileOpError)?.message ?? error.localizedDescription
        }
        isLoading = false
    }

    func save() async {
        guard isDirty, !isSaving else { return }
        isSaving = true
        do {
            try await backend.save(content, to: item)
            savedContent = content
        } catch {
            self.error = (error as? FileOpError)?.message ?? error.localizedDescription
        }
        isSaving = false
    }

    /// Called on each edit. Auto-saves (debounced) when that preference is on.
    func didEdit() {
        objectWillChange.send()  // refresh the dirty indicator
        guard SFTPSettings.shared.autoSave else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in Task { await self?.save() } }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

/// File viewer pane: header (name, Rendered/Raw for Markdown, 3-dot menu, close)
/// over a syntax-highlighted code view or a rendered-Markdown web view.
struct FileViewerView: View {
    @ObservedObject var model: FileViewerModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
        }
        // Opaque blur backdrop so the file manager is hidden/blurred behind the
        // viewer instead of bleeding through.
        .background(.regularMaterial)
        .onAppear { Task { await model.load() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(model.item.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)

            if model.isMarkdown {
                Picker("", selection: $model.renderMarkdown) {
                    Text("Rendered").tag(true)
                    Text("Raw").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }

            // Save indicator/button — only when there are unsaved edits.
            if model.isDirty {
                Button { Task { await model.save() } } label: {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.down.circle.fill") }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut("s", modifiers: .command)
                .hoverTip("Save (⌘S)")
            }

            Menu {
                Button("Refresh file") { Task { await model.load() } }
                if let url = model.localURL {
                    Button("Open in editor") { NSWorkspace.shared.open(url) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Copy file path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.item.path, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverTip("More")

            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).hoverTip("Close")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            VStack { ProgressView(); Text("Loading…").font(.caption).foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else if model.isMarkdown && model.renderMarkdown {
            MarkdownWebView(markdown: model.content)
        } else {
            CodeEditorView(text: $model.content, onEdit: { model.didEdit() })
        }
    }
}

// MARK: - Editable code editor (NSTextView: line numbers + highlighting)

private struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .textColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        // Line-number gutter.
        scroll.verticalRulerView = LineNumberRulerView(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
        context.coordinator.highlight(tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeEditorView
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
            parent.onEdit()
        }

        /// Re-color the whole document (fine for typical source files).
        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            CodeHighlighter.apply(to: storage)
            storage.endEditing()
        }
    }
}

/// Simple left gutter showing 1-based line numbers for an NSTextView.
private final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer,
              let scroll = scrollView else { return }
        let content = tv.string as NSString
        let inset = tv.textContainerInset.height
        let visible = scroll.documentVisibleRect
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: container)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Line number of the first visible character.
        var line = 1
        if charRange.location > 0 {
            content.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location),
                                        options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        }

        var index = charRange.location
        while index <= NSMaxRange(charRange) {
            let lineRange = content.lineRange(for: NSRange(location: index, length: 0))
            let lineGlyphRange = lm.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let frag = lm.lineFragmentRect(forGlyphAt: lineGlyphRange.location, effectiveRange: nil)
            let y = frag.minY + inset - visible.minY
            let num = "\(line)" as NSString
            let size = num.size(withAttributes: attrs)
            num.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + (frag.height - size.height) / 2),
                     withAttributes: attrs)
            line += 1
            if lineRange.length == 0 { break }
            index = NSMaxRange(lineRange)
            if index >= content.length { break }
        }
    }
}

/// Minimal, language-agnostic highlighter: numbers, strings, comments.
/// Applied across the whole document; dependency-free.
enum CodeHighlighter {
    private static let patterns: [(NSRegularExpression?, NSColor)] = [
        (try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b"), .systemTeal),
        (try? NSRegularExpression(pattern: "\"[^\"]*\"|'[^']*'|`[^`]*`"), .systemGreen),
        // line comments (// or #) and block comments — comment colour wins (last).
        (try? NSRegularExpression(pattern: "//.*|#.*|/\\*[\\s\\S]*?\\*/"), .systemGray),
    ]

    static func apply(to storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        for (re, color) in patterns {
            re?.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
    }
}

// MARK: - Markdown (rendered via WKWebView)

private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")  // transparent so our bg shows
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(MarkdownHTML.page(from: markdown), baseURL: nil)
    }
}
