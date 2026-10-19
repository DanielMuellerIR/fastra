import AppKit
import WebKit

enum MarkdownPresentation {
    static let css = """
    @media screen {
      body > :where(:not(#fastra-visual):not(#fastra-code-controls)), #fastra-visual > * {
        max-width: 650px; margin-inline: auto; box-sizing: border-box;
      }
      body > table, body > :has(table), #fastra-visual > :has(table) { max-width: 100%; }
      table { display: block; width: max-content; max-width: 100%; overflow-x: auto; margin-inline: auto; }
      pre { overflow-x: auto; box-sizing: border-box; }
      pre:has(> code) { padding-top: 2.7em; }
    }
    #fastra-code-controls { position: absolute; top: 0; left: 0; width: 0; height: 0;
      user-select: none; -webkit-user-select: none; }
    .fastra-code-copy { position: absolute; width: 28px; height: 28px; padding: 5px;
      display: grid; place-items: center; border: 1px solid var(--fastra-copy-border);
      border-radius: 5px; color: inherit; background: var(--fastra-copy-background);
      cursor: pointer; z-index: 2; }
    .fastra-code-copy:hover { filter: brightness(1.12); }
    .fastra-code-copy[hidden] { display: none; }
    .fastra-code-copy:focus-visible { outline: 2px solid -apple-system-control-accent; outline-offset: 2px; }
    .fastra-code-copy svg { width: 16px; height: 16px; fill: none; stroke: currentColor;
      stroke-width: 1.5; pointer-events: none; }
    @media print { #fastra-code-controls { display: none !important; } }
    """

    @MainActor
    static func copyCode(_ payload: [String: Any], in webView: WKWebView?,
                         pasteboard: NSPasteboard = .general) {
        guard let text = payload["text"] as? String,
              let request = payload["request"] as? Int, request >= 0 else { return }
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        webView?.callAsyncJavaScript("window.fastraMarkdownPresentation?.didCopy(request, copied);",
                                    arguments: ["request": request, "copied": copied],
                                    in: nil, in: .page, completionHandler: nil)
    }
}
