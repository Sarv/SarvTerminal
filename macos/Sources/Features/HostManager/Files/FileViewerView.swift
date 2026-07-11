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

    /// Files open read-only (View). The header pencil unlocks editing.
    @Published var isEditing = false

    /// Wrap long lines to the viewer width (toggle in the ⋯ menu).
    @Published var wordWrap = true

    /// highlight.js language id for syntax coloring — auto-detected from the
    /// file extension, overridable via the header dropdown.
    @Published var language: String

    /// Soft-tab width in spaces (Tab inserts this many). Seeded from the SFTP
    /// default; the header dropdown overrides it for this file.
    @Published var indentWidth: Int

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
        self.language = CodeLang.detect(from: item.name)
        self.indentWidth = SFTPSettings.shared.indentWidth
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
            Image(systemName: "doc.text").foregroundStyle(.secondaryText)
            Text(model.item.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 12)

            if model.isMarkdown {
                Picker("", selection: $model.renderMarkdown) {
                    Text("Rendered").tag(true)
                    Text("Raw").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }

            // Editing → "Save changes" (saves, then returns to View).
            // View → pencil to start editing (code view only; Markdown via Raw).
            if model.isEditing {
                Button {
                    Task { await model.save(); if model.error == nil { model.isEditing = false } }
                } label: {
                    if model.isSaving { ProgressView().controlSize(.small) }
                    else { Label("Save changes", systemImage: "checkmark.circle.fill") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .hoverTip("Save changes (⌘S)")
            } else if !(model.isMarkdown && model.renderMarkdown) {
                Button { model.isEditing = true } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverTip("Edit file")
            }

            // Language menu for syntax highlighting (code view only). A pull-down
            // Menu (not a .menu Picker) so it always opens downward instead of
            // centering the selected row over the button and opening upward.
            if !(model.isMarkdown && model.renderMarkdown) {
                Menu {
                    ForEach(CodeLang.common) { lang in
                        Button {
                            model.language = lang.id
                        } label: {
                            if model.language == lang.id {
                                Label(lang.label, systemImage: "checkmark")
                            } else {
                                Text(lang.label)
                            }
                        }
                    }
                } label: {
                    Text(CodeLang.label(for: model.language)).font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .hoverTip("Syntax highlighting")
            }

            // Indent width (Tab inserts this many spaces) — edit mode only.
            if model.isEditing {
                Menu {
                    Button { model.indentWidth = 2 } label: {
                        if model.indentWidth == 2 { Label("2 spaces", systemImage: "checkmark") } else { Text("2 spaces") }
                    }
                    Button { model.indentWidth = 4 } label: {
                        if model.indentWidth == 4 { Label("4 spaces", systemImage: "checkmark") } else { Text("4 spaces") }
                    }
                } label: {
                    Text("Indent: \(model.indentWidth)").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .hoverTip("Indent width")
            }

            Menu {
                Toggle("Word wrap", isOn: $model.wordWrap)
                Divider()
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
            VStack { ProgressView(); Text("Loading…").font(.caption).foregroundStyle(.secondaryText) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark").font(.system(size: 36)).foregroundStyle(.tertiaryText)
                Text(error).foregroundStyle(.secondaryText).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else if model.isMarkdown && model.renderMarkdown {
            MarkdownWebView(markdown: model.content)
        } else {
            CodeEditorView(text: $model.content, isEditable: model.isEditing, wordWrap: model.wordWrap, language: model.language, indentWidth: model.indentWidth, onEdit: { model.didEdit() })
        }
    }
}

// MARK: - Editable code editor (NSTextView: line numbers + highlighting)

private struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wordWrap: Bool
    var language: String
    var indentWidth: Int
    let onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isEditable = isEditable
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
        tv.string = text
        applyWrap(tv, scroll)

        // Line-number gutter.
        scroll.verticalRulerView = LineNumberRulerView(textView: tv)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.isEditable != isEditable { tv.isEditable = isEditable }
        context.coordinator.indentWidth = indentWidth
        if (tv.textContainer?.widthTracksTextView ?? false) != wordWrap { applyWrap(tv, scroll) }
        if tv.string != text {
            tv.string = text
            context.coordinator.language = language
            context.coordinator.highlight(tv)
        } else if context.coordinator.language != language {
            context.coordinator.language = language
            context.coordinator.highlight(tv)
        }
    }

    /// Toggle line wrapping: track the view width when wrapping, or grow
    /// horizontally with a scroller when not.
    private func applyWrap(_ tv: NSTextView, _ scroll: NSScrollView) {
        guard let container = tv.textContainer else { return }
        let big = CGFloat.greatestFiniteMagnitude
        if wordWrap {
            scroll.hasHorizontalScroller = false
            tv.isHorizontallyResizable = false
            let w = scroll.contentSize.width
            tv.frame.size.width = w
            tv.maxSize = NSSize(width: w, height: big)
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: w, height: big)
        } else {
            scroll.hasHorizontalScroller = true
            tv.isHorizontallyResizable = true
            tv.maxSize = NSSize(width: big, height: big)
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: big, height: big)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeEditorView
        var language: String
        var indentWidth: Int

        init(_ parent: CodeEditorView) {
            self.parent = parent
            self.language = parent.language
            self.indentWidth = parent.indentWidth
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            highlight(tv)
            parent.onEdit()
        }

        /// Auto-indent a new line to match the current line, and insert soft
        /// tabs (indentWidth spaces) instead of a hard tab.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let s = textView.string as NSString
                let lineRange = s.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0))
                let indent = s.substring(with: lineRange).prefix { $0 == " " || $0 == "\t" }
                textView.insertText("\n" + String(indent), replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText(String(repeating: " ", count: indentWidth), replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }

        /// Re-color the whole document via Highlightr for the current language
        /// (or plain text). Only foreground colors are copied over, so the
        /// monospaced font and the editing cursor/selection are preserved.
        func highlight(_ tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            if language != "plaintext" {
                CodeSyntax.apply(to: storage, language: language)
            }
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

/// A syntax-highlighting language for the viewer dropdown, plus extension→id
/// detection. `id` is a highlight.js language identifier understood by Highlightr.
struct CodeLang: Identifiable {
    let id: String
    let label: String

    /// The curated set shown in the header dropdown.
    static let common: [CodeLang] = [
        .init(id: "plaintext", label: "Plain Text"),
        .init(id: "bash", label: "Shell"),
        .init(id: "c", label: "C"),
        .init(id: "cpp", label: "C++"),
        .init(id: "csharp", label: "C#"),
        .init(id: "css", label: "CSS"),
        .init(id: "diff", label: "Diff"),
        .init(id: "dockerfile", label: "Dockerfile"),
        .init(id: "go", label: "Go"),
        .init(id: "html", label: "HTML"),
        .init(id: "ini", label: "INI"),
        .init(id: "java", label: "Java"),
        .init(id: "javascript", label: "JavaScript"),
        .init(id: "json", label: "JSON"),
        .init(id: "kotlin", label: "Kotlin"),
        .init(id: "lua", label: "Lua"),
        .init(id: "makefile", label: "Makefile"),
        .init(id: "markdown", label: "Markdown"),
        .init(id: "nginx", label: "Nginx"),
        .init(id: "objectivec", label: "Objective-C"),
        .init(id: "perl", label: "Perl"),
        .init(id: "php", label: "PHP"),
        .init(id: "python", label: "Python"),
        .init(id: "ruby", label: "Ruby"),
        .init(id: "rust", label: "Rust"),
        .init(id: "scss", label: "SCSS"),
        .init(id: "sql", label: "SQL"),
        .init(id: "swift", label: "Swift"),
        .init(id: "toml", label: "TOML"),
        .init(id: "typescript", label: "TypeScript"),
        .init(id: "xml", label: "XML / HTML"),
        .init(id: "yaml", label: "YAML"),
    ]

    /// Display label for a language id (falls back to Plain Text).
    static func label(for id: String) -> String {
        common.first { $0.id == id }?.label ?? "Plain Text"
    }

    /// Best-guess language id from a filename. Falls back to plain text.
    static func detect(from filename: String) -> String {
        let name = (filename as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        default: break
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "sh", "bash", "zsh", "fish", "zshrc", "bashrc", "profile": return "bash"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "cs": return "csharp"
        case "css": return "css"
        case "diff", "patch": return "diff"
        case "go": return "go"
        case "htm", "html", "xhtml": return "html"
        case "ini", "cfg", "conf": return "ini"
        case "java": return "java"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "json": return "json"
        case "kt", "kts": return "kotlin"
        case "lua": return "lua"
        case "md", "markdown": return "markdown"
        case "m": return "objectivec"
        case "pl", "pm": return "perl"
        case "php": return "php"
        case "py", "pyw": return "python"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "scss": return "scss"
        case "sql": return "sql"
        case "swift": return "swift"
        case "toml": return "toml"
        case "ts", "tsx": return "typescript"
        case "xml", "plist", "storyboard", "xib", "svg": return "xml"
        case "yml", "yaml": return "yaml"
        default: return "plaintext"
        }
    }
}

/// Lightweight, dependency-free syntax highlighter: per-language keywords plus
/// generic strings / numbers / comments. Colors are fixed semantic system
/// colors (legible in both light and dark), independent of the terminal theme.
enum CodeSyntax {
    private static let keywordColor = NSColor.systemPurple
    private static let stringColor = NSColor.systemGreen
    private static let numberColor = NSColor.systemTeal
    private static let commentColor = NSColor.systemGray
    private static let tagColor = NSColor.systemBlue

    struct Rules {
        var keywords: [String]
        var line: [String]
        var block: (open: String, close: String)?
        var strings: [String]
        var markup: Bool
    }

    static func apply(to storage: NSTextStorage, language: String) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let r = rules(for: language)

        func color(_ pattern: String, _ c: NSColor) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                if let rng = m?.range { storage.addAttribute(.foregroundColor, value: c, range: rng) }
            }
        }

        // Lowest priority first; later passes override overlapping ranges.
        color("\\b0[xX][0-9a-fA-F]+\\b|\\b\\d[\\d_]*(?:\\.\\d+)?\\b", numberColor)
        if !r.keywords.isEmpty {
            let alt = r.keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            color("\\b(?:\(alt))\\b", keywordColor)
        }
        if r.markup { color("</?[A-Za-z][A-Za-z0-9:_-]*", tagColor) }
        // Strings override keywords/numbers that fall inside them.
        for d in r.strings { color(stringPattern(for: d), stringColor) }
        // Comments win last.
        if let b = r.block {
            let o = NSRegularExpression.escapedPattern(for: b.open)
            let c = NSRegularExpression.escapedPattern(for: b.close)
            color("\(o)[\\s\\S]*?\(c)", commentColor)
        }
        for lc in r.line {
            color("\(NSRegularExpression.escapedPattern(for: lc)).*", commentColor)
        }
    }

    private static func stringPattern(for delim: String) -> String {
        switch delim {
        case "\"": return #"\"(?:\\.|[^\"\\\n])*\""#
        case "'": return #"'(?:\\.|[^'\\\n])*'"#
        case "`": return #"`(?:\\.|[^`\\])*`"#
        default:
            let e = NSRegularExpression.escapedPattern(for: delim)
            return "\(e)[^\n]*?\(e)"
        }
    }

    private static func rules(for lang: String) -> Rules {
        switch lang {
        case "swift":
            return Rules(keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "while", "switch", "case", "default", "struct", "class", "enum", "protocol", "extension", "import", "self", "init", "deinit", "throws", "try", "catch", "do", "defer", "in", "where", "as", "is", "nil", "true", "false", "public", "private", "internal", "fileprivate", "static", "final", "lazy", "weak", "unowned", "async", "await", "some", "any"], line: ["//"], block: ("/*", "*/"), strings: ["\""], markup: false)
        case "javascript", "typescript":
            return Rules(keywords: ["function", "let", "const", "var", "if", "else", "return", "for", "while", "switch", "case", "default", "class", "extends", "new", "this", "import", "export", "from", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "void", "yield", "interface", "type", "enum", "implements", "readonly"], line: ["//"], block: ("/*", "*/"), strings: ["\"", "'", "`"], markup: false)
        case "python":
            return Rules(keywords: ["def", "class", "if", "elif", "else", "return", "for", "while", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "pass", "break", "continue", "in", "is", "not", "and", "or", "None", "True", "False", "async", "await", "self"], line: ["#"], block: nil, strings: ["\"", "'"], markup: false)
        case "go":
            return Rules(keywords: ["func", "var", "const", "package", "import", "if", "else", "for", "range", "return", "switch", "case", "default", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "break", "continue", "nil", "true", "false", "iota"], line: ["//"], block: ("/*", "*/"), strings: ["\"", "`"], markup: false)
        case "rust":
            return Rules(keywords: ["fn", "let", "mut", "const", "if", "else", "match", "for", "while", "loop", "return", "struct", "enum", "trait", "impl", "use", "mod", "pub", "crate", "self", "super", "as", "in", "ref", "move", "async", "await", "dyn", "where", "Some", "None", "Ok", "Err", "true", "false"], line: ["//"], block: ("/*", "*/"), strings: ["\""], markup: false)
        case "c", "cpp", "objectivec":
            return Rules(keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "struct", "union", "enum", "typedef", "const", "static", "extern", "return", "if", "else", "for", "while", "switch", "case", "default", "break", "continue", "sizeof", "class", "public", "private", "protected", "virtual", "namespace", "template", "new", "delete", "nullptr", "true", "false", "auto"], line: ["//"], block: ("/*", "*/"), strings: ["\"", "'"], markup: false)
        case "java", "kotlin", "csharp":
            return Rules(keywords: ["class", "interface", "enum", "public", "private", "protected", "static", "final", "void", "int", "long", "double", "float", "boolean", "char", "String", "if", "else", "for", "while", "switch", "case", "default", "return", "new", "this", "super", "try", "catch", "finally", "throw", "throws", "import", "package", "extends", "implements", "abstract", "null", "true", "false", "var", "val", "fun", "namespace", "using"], line: ["//"], block: ("/*", "*/"), strings: ["\"", "'"], markup: false)
        case "php":
            return Rules(keywords: ["function", "class", "public", "private", "protected", "static", "if", "else", "elseif", "foreach", "for", "while", "return", "new", "echo", "print", "require", "include", "use", "namespace", "try", "catch", "throw", "null", "true", "false", "array", "as"], line: ["//", "#"], block: ("/*", "*/"), strings: ["\"", "'"], markup: false)
        case "ruby":
            return Rules(keywords: ["def", "class", "module", "if", "elsif", "else", "unless", "end", "return", "do", "yield", "require", "include", "begin", "rescue", "ensure", "raise", "then", "while", "until", "case", "when", "nil", "true", "false", "self", "and", "or", "not"], line: ["#"], block: nil, strings: ["\"", "'"], markup: false)
        case "bash":
            return Rules(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "in", "export", "local", "echo", "exit", "source", "alias"], line: ["#"], block: nil, strings: ["\"", "'"], markup: false)
        case "sql":
            return Rules(keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "INDEX", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "UNIQUE"], line: ["--"], block: ("/*", "*/"), strings: ["'"], markup: false)
        case "css", "scss":
            return Rules(keywords: [], line: [], block: ("/*", "*/"), strings: ["\"", "'"], markup: false)
        case "json":
            return Rules(keywords: ["true", "false", "null"], line: [], block: nil, strings: ["\""], markup: false)
        case "yaml", "toml", "ini":
            return Rules(keywords: ["true", "false", "null", "yes", "no"], line: ["#", ";"], block: nil, strings: ["\"", "'"], markup: false)
        case "html", "xml", "markdown":
            return Rules(keywords: [], line: [], block: ("<!--", "-->"), strings: ["\""], markup: true)
        case "lua":
            return Rules(keywords: ["function", "local", "if", "then", "else", "elseif", "end", "for", "while", "do", "repeat", "until", "return", "break", "nil", "true", "false", "and", "or", "not", "in"], line: ["--"], block: ("--[[", "]]"), strings: ["\"", "'"], markup: false)
        case "dockerfile":
            return Rules(keywords: ["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "HEALTHCHECK", "SHELL"], line: ["#"], block: nil, strings: ["\"", "'"], markup: false)
        default:
            return Rules(keywords: [], line: ["//", "#"], block: ("/*", "*/"), strings: ["\"", "'", "`"], markup: false)
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
