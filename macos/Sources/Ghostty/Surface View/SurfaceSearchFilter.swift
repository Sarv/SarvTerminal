import SwiftUI
import GhosttyKit

/// grep-style line filter for the terminal search bar: matching lines plus
/// `before`/`after` context (grep `-B`/`-A`). The matching is done incrementally
/// by `IncrementalLineFilter` so a fast-streaming `tail -f` only re-scans the
/// newly-appended lines, not the whole scrollback, on each poll.
enum SearchLineFilter {
    /// One emitted line of the filtered output.
    struct Line: Equatable {
        let number: Int      // 1-based position in the current buffer
        let text: String
        let isMatch: Bool
    }

    /// Render item: a line, or a thin divider between/after match blocks.
    enum Item: Identifiable {
        case line(Line)
        case divider(Int)    // carries a unique id
        var id: Int {
            switch self {
            case .line(let l): return l.number * 2
            case .divider(let i): return i * 2 + 1
            }
        }
    }

    /// A reusable matcher: plain substring (case-sensitive or not) or a regex.
    /// Built once per options change so the regex isn't recompiled per line.
    struct Matcher: Equatable {
        let needle: String
        let caseSensitive: Bool
        let useRegex: Bool
        private let regex: NSRegularExpression?
        let isValid: Bool

        init(needle: String, caseSensitive: Bool, useRegex: Bool) {
            self.needle = needle
            self.caseSensitive = caseSensitive
            self.useRegex = useRegex
            if needle.isEmpty {
                regex = nil; isValid = false
            } else if useRegex {
                let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
                regex = try? NSRegularExpression(pattern: needle, options: opts)
                isValid = regex != nil   // invalid regex → matches nothing (no break)
            } else {
                regex = nil; isValid = true
            }
        }

        /// Identity for change-detection (two matchers behave the same iff equal).
        var signature: String { "\(useRegex ? "r" : "s")\(caseSensitive ? "c" : "i")\u{1}\(needle)" }

        static func == (a: Matcher, b: Matcher) -> Bool { a.signature == b.signature }

        func matches(_ line: String) -> Bool {
            if let regex {
                return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }
            return line.range(of: needle, options: caseSensitive ? [] : .caseInsensitive) != nil
        }

        /// Ranges of every match in `line`, for highlighting.
        func ranges(in line: String) -> [Range<String.Index>] {
            if let regex {
                return regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
                    .compactMap { Range($0.range, in: line) }
                    .filter { !$0.isEmpty }
            }
            var out: [Range<String.Index>] = []
            var start = line.startIndex
            while start < line.endIndex,
                  let r = line.range(of: needle, options: caseSensitive ? [] : .caseInsensitive,
                                     range: start..<line.endIndex) {
                out.append(r)
                start = r.upperBound > r.lowerBound ? r.upperBound : line.index(after: r.lowerBound)
            }
            return out
        }
    }

    /// Highlight every match of `matcher` in `line`.
    static func highlighted(_ line: String, matcher: Matcher) -> AttributedString {
        var attr = AttributedString(line)
        for r in matcher.ranges(in: line) {
            if let lo = AttributedString.Index(r.lowerBound, within: attr),
               let hi = AttributedString.Index(r.upperBound, within: attr) {
                attr[lo..<hi].backgroundColor = .yellow
                attr[lo..<hi].foregroundColor = .black
            }
        }
        return attr
    }
}

/// Stateful, incremental grep-with-context over a growing terminal buffer.
///
/// On each poll it folds only the lines that are NEW since the last poll into
/// the existing result (the common `tail -f` append case), so per-tick matching
/// cost is O(new lines) rather than O(whole buffer). If the buffer changes in a
/// way that isn't a pure append (scrollback eviction, screen clear, alt-screen,
/// or any option change), it transparently rebuilds from scratch.
final class IncrementalLineFilter {
    /// Cap on retained output lines so a long-running tail doesn't grow without
    /// bound; oldest filtered lines are dropped.
    private let maxLines = 8000

    private(set) var lines: [SearchLineFilter.Line] = []

    private var prevComplete: [String] = []
    private var beforeBuf: [(no: Int, text: String)] = []   // last `before` source lines
    private var afterRemaining = 0
    private var lastEmittedNo = -1
    private var signature = ""

    func reset() {
        lines = []; prevComplete = []; beforeBuf = []
        afterRemaining = 0; lastEmittedNo = -1; signature = ""
    }

    /// Update against the latest full scrollback text. Returns true if `lines`
    /// changed (so the caller can refresh the view only when needed).
    @discardableResult
    func update(rawText: String, matcher: SearchLineFilter.Matcher, before: Int, after: Int) -> Bool {
        let b = max(0, before), a = max(0, after)
        let sig = "\(matcher.signature)\u{1}\(b)\u{1}\(a)"
        // Drop the volatile trailing element (an incomplete line / the cursor
        // row); grep matches whole lines, and it'll be folded once it completes.
        let complete = Array(rawText.components(separatedBy: "\n").dropLast())

        if sig != signature {
            signature = sig
            rebuild(complete, matcher, b, a)
            return true
        }
        if isPureAppend(of: complete) {
            let base = prevComplete.count
            let newLines = Array(complete[base...])
            prevComplete = complete
            guard !newLines.isEmpty else { return false }
            let countBefore = lines.count
            fold(newLines, firstNumber: base + 1, matcher: matcher, before: b, after: a)
            return lines.count != countBefore
        }
        rebuild(complete, matcher, b, a)
        return true
    }

    // MARK: - Internals

    /// Cheap O(1) check: the previously-last committed line is still at the same
    /// index. True for pure appends; false for eviction / rewrite / clear.
    private func isPureAppend(of complete: [String]) -> Bool {
        guard !prevComplete.isEmpty, complete.count >= prevComplete.count else { return false }
        let i = prevComplete.count - 1
        if complete[i] != prevComplete[i] { return false }
        if i >= 1 && complete[i - 1] != prevComplete[i - 1] { return false }
        return true
    }

    private func rebuild(_ complete: [String], _ matcher: SearchLineFilter.Matcher, _ before: Int, _ after: Int) {
        prevComplete = complete
        beforeBuf = []; afterRemaining = 0; lastEmittedNo = -1; lines = []
        guard matcher.isValid else { return }
        fold(complete, firstNumber: 1, matcher: matcher, before: before, after: after)
    }

    /// Fold a run of source lines into the output, maintaining grep -A/-B state.
    private func fold(_ source: [String], firstNumber: Int,
                      matcher: SearchLineFilter.Matcher, before: Int, after: Int) {
        var no = firstNumber
        for text in source {
            if matcher.matches(text) {
                // Emit any not-yet-shown before-context, then the match.
                for ctx in beforeBuf where ctx.no > lastEmittedNo {
                    lines.append(.init(number: ctx.no, text: ctx.text, isMatch: false))
                    lastEmittedNo = ctx.no
                }
                lines.append(.init(number: no, text: text, isMatch: true))
                lastEmittedNo = no
                afterRemaining = after
            } else if afterRemaining > 0 {
                if no > lastEmittedNo {
                    lines.append(.init(number: no, text: text, isMatch: false))
                    lastEmittedNo = no
                }
                afterRemaining -= 1
            }
            if before > 0 {
                beforeBuf.append((no, text))
                if beforeBuf.count > before { beforeBuf.removeFirst() }
            }
            no += 1
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}

extension Ghostty {
    /// A tiny numeric field for the before/after context counts. Accepts digits
    /// only; anything else is ignored rather than breaking the filter — an empty
    /// or invalid entry simply keeps the last valid value.
    struct SearchContextField: View {
        @Binding var value: Int
        @State private var text: String = ""

        var body: some View {
            TextField("", text: $text)
                .frame(width: 38)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .onAppear { text = String(value) }
                .onChange(of: value) { newValue in
                    if Int(text) != newValue { text = String(newValue) }
                }
                .onChange(of: text) { newText in
                    let digits = String(newText.filter(\.isNumber).prefix(4))
                    if digits != newText { text = digits; return }  // strip junk, no-op otherwise
                    if let n = Int(digits) { value = n }             // empty/invalid → leave value as-is
                }
        }
    }

    /// Full-surface overlay that replaces the live terminal with a grep-filtered
    /// view of its scrollback while "Only matching lines" is enabled in the
    /// search bar. Polls the scrollback so a live `tail -f` keeps updating.
    struct SurfaceSearchFilterOverlay: View {
        let surfaceView: SurfaceView
        @ObservedObject var searchState: SurfaceView.SearchState
        let backgroundColor: Color

        @State private var displayLines: [SearchLineFilter.Line] = []
        @State private var matcher = SearchLineFilter.Matcher(needle: "", caseSensitive: false, useRegex: false)
        @State private var engine = IncrementalLineFilter()

        private var active: Bool {
            searchState.filterEnabled && !searchState.needle.isEmpty
        }

        private var matchCount: Int { displayLines.reduce(0) { $1.isMatch ? $0 + 1 : $0 } }

        /// Build render items (lines + dividers) from the small filtered result.
        /// A divider is drawn where line numbers are non-contiguous (between
        /// blocks) and once after the final block.
        private var items: [SearchLineFilter.Item] {
            var out: [SearchLineFilter.Item] = []
            var prev = -1
            var dividerID = 0
            for ln in displayLines {
                if prev != -1 && ln.number != prev + 1 {
                    out.append(.divider(dividerID)); dividerID += 1
                }
                out.append(.line(ln))
                prev = ln.number
            }
            if !displayLines.isEmpty { out.append(.divider(dividerID)) }
            return out
        }

        var body: some View {
            Group {
                if active {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        content
                    }
                    .background(backgroundColor)
                    .transition(.opacity)
                    .onAppear(perform: refresh)
                    .onChange(of: searchState.needle) { _ in refresh() }
                    .onChange(of: searchState.linesBefore) { _ in refresh() }
                    .onChange(of: searchState.linesAfter) { _ in refresh() }
                    .onChange(of: searchState.caseSensitive) { _ in refresh() }
                    .onChange(of: searchState.useRegex) { _ in refresh() }
                    .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
                        refresh()
                    }
                }
            }
        }

        private var header: some View {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filtered").font(.caption.weight(.semibold))
                Text("“\(searchState.needle)”").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(matchCount) match\(matchCount == 1 ? "" : "es") · −\(searchState.linesBefore)B / +\(searchState.linesAfter)A")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }

        @ViewBuilder
        private var content: some View {
            if displayLines.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.title2).foregroundColor(.secondary)
                    Text("No matching lines").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(items) { row($0) }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: displayLines.count) { _ in
                        // Tail behavior: keep the newest matching lines in view.
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }

        @ViewBuilder
        private func row(_ item: SearchLineFilter.Item) -> some View {
            switch item {
            case .divider:
                // Thin horizontal rule separating match blocks.
                Rectangle()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            case .line(let ln):
                HStack(alignment: .top, spacing: 10) {
                    Text("\(ln.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(width: 52, alignment: .trailing)
                    Text(ln.isMatch ? SearchLineFilter.highlighted(ln.text, matcher: matcher)
                                    : AttributedString(ln.text))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(ln.isMatch ? .primary : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        private func refresh() {
            guard active else {
                if !displayLines.isEmpty { displayLines = [] }
                engine.reset()
                return
            }
            let raw = surfaceView.liveScreenText()
            let m = SearchLineFilter.Matcher(
                needle: searchState.needle,
                caseSensitive: searchState.caseSensitive,
                useRegex: searchState.useRegex)
            matcher = m
            // Incremental: only the newly-appended lines are re-scanned.
            if engine.update(rawText: raw, matcher: m,
                             before: searchState.linesBefore, after: searchState.linesAfter) {
                displayLines = engine.lines
            }
        }
    }
}
