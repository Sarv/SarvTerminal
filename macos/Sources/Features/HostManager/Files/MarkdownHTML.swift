import Foundation

/// Tiny, dependency-free Markdown → HTML converter for the file viewer.
/// Handles headings, bold/italic, inline + fenced code, links, lists,
/// blockquotes, and horizontal rules — enough to render docs/README/CLAUDE.md.
enum MarkdownHTML {

    static func page(from markdown: String) -> String {
        "<!doctype html><html><head><meta charset='utf-8'>\(style)</head><body>\(body(markdown))</body></html>"
    }

    // MARK: Block parsing

    private static func body(_ md: String) -> String {
        var html = ""
        var inFence = false
        var fence: [String] = []
        var list: String?            // "ul" or "ol" while inside a list
        let lines = md.components(separatedBy: "\n")

        func closeList() { if let l = list { html += "</\(l)>"; list = nil } }

        for raw in lines {
            // Fenced code blocks ``` … ```
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    html += "<pre><code>\(escape(fence.joined(separator: "\n")))</code></pre>"
                    fence = []; inFence = false
                } else {
                    closeList(); inFence = true
                }
                continue
            }
            if inFence { fence.append(raw); continue }

            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { closeList(); continue }

            // Horizontal rule
            if line == "---" || line == "***" || line == "___" { closeList(); html += "<hr>"; continue }

            // Headings
            if let h = heading(line) { closeList(); html += h; continue }

            // Blockquote
            if line.hasPrefix("> ") { closeList(); html += "<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"; continue }

            // Lists
            if let item = unordered(line) {
                if list != "ul" { closeList(); html += "<ul>"; list = "ul" }
                html += "<li>\(inline(item))</li>"; continue
            }
            if let item = ordered(line) {
                if list != "ol" { closeList(); html += "<ol>"; list = "ol" }
                html += "<li>\(inline(item))</li>"; continue
            }

            // Paragraph
            closeList()
            html += "<p>\(inline(line))</p>"
        }
        if inFence { html += "<pre><code>\(escape(fence.joined(separator: "\n")))</code></pre>" }
        closeList()
        return html
    }

    private static func heading(_ line: String) -> String? {
        var level = 0
        for c in line { if c == "#" { level += 1 } else { break } }
        guard level >= 1, level <= 6, line.dropFirst(level).first == " " else { return nil }
        let text = String(line.dropFirst(level + 1))
        return "<h\(level)>\(inline(text))</h\(level)>"
    }

    private static func unordered(_ line: String) -> String? {
        for p in ["- ", "* ", "+ "] where line.hasPrefix(p) { return String(line.dropFirst(2)) }
        return nil
    }

    private static func ordered(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return String(line[line.index(after: after)...])
    }

    // MARK: Inline parsing (escape first, then markup)

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, #"`([^`]+)`"#, "<code>$1</code>")
        s = replace(s, #"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>")
        s = replace(s, #"\*\*([^*]+)\*\*"#, "<strong>$1</strong>")
        s = replace(s, #"__([^_]+)__"#, "<strong>$1</strong>")
        s = replace(s, #"\*([^*]+)\*"#, "<em>$1</em>")
        s = replace(s, #"_([^_]+)_"#, "<em>$1</em>")
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Styling (dark, matches the app)

    private static let style = """
    <style>
      :root { color-scheme: dark; }
      body { font: 14px -apple-system, system-ui, sans-serif; color: #d8dee9;
             padding: 18px 22px; line-height: 1.6; }
      h1,h2,h3,h4 { color: #fff; line-height: 1.25; margin: 1.2em 0 .5em; }
      h1 { font-size: 1.9em; border-bottom: 1px solid #3b4252; padding-bottom: .2em; }
      h2 { font-size: 1.5em; border-bottom: 1px solid #3b4252; padding-bottom: .2em; }
      h3 { font-size: 1.25em; } h4 { font-size: 1.05em; }
      a { color: #88c0d0; }
      code { font-family: ui-monospace, Menlo, monospace; font-size: .9em;
             background: rgba(255,255,255,.08); padding: .1em .35em; border-radius: 4px; color: #ebcb8b; }
      pre { background: rgba(0,0,0,.30); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
      pre code { background: none; padding: 0; color: #d8dee9; }
      blockquote { border-left: 3px solid #4c566a; margin: .6em 0; padding: .2em 0 .2em 12px; color: #aeb7c6; }
      ul,ol { padding-left: 1.4em; }
      hr { border: none; border-top: 1px solid #3b4252; margin: 1.2em 0; }
      table { border-collapse: collapse; } td,th { border: 1px solid #3b4252; padding: 4px 8px; }
    </style>
    """
}
