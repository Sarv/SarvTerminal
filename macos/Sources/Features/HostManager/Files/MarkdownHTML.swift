import Foundation
import GhosttyKit

/// Markdown → HTML for the file viewer. The actual rendering is done by **md4c
/// in the core** (`ghostty_markdown_to_html` — CommonMark + GFM tables, task
/// lists, strikethrough, with raw HTML escaped for safety); this type only wraps
/// the result in a styled page so the same engine serves every platform.
/// See `pkg/md4c` and `src/markdown.zig`.
enum MarkdownHTML {

    static func page(from markdown: String) -> String {
        "<!doctype html><html><head><meta charset='utf-8'>\(style)</head><body>\(body(markdown))</body></html>"
    }

    /// Render the markdown body to HTML via md4c. Falls back to the raw text in a
    /// `<pre>` block if the renderer yields nothing for non-empty input.
    private static func body(_ md: String) -> String {
        let html = md.withCString { cptr in
            Ghostty.AllocatedString(
                ghostty_markdown_to_html(cptr, UInt(strlen(cptr)))
            ).string
        }
        if html.isEmpty && !md.isEmpty { return "<pre>\(escape(md))</pre>" }
        return html
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
      table { border-collapse: collapse; margin: .6em 0; }
      td,th { border: 1px solid #3b4252; padding: 4px 8px; }
      th { background: rgba(255,255,255,.05); }
      img { max-width: 100%; }
    </style>
    """
}
