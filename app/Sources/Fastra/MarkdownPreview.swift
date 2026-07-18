// MarkdownPreview.swift
//
// Read-only Markdown-Vorschau, eingebettet rechts neben dem Editor
// (siehe `showsIntegratedMarkdownPreview` in EditorView.swift).
//
// Design-Entscheidungen:
//   • Live-Aktualisierung über @ObservedObject Workspace: der Inhalt des
//     aktiven Tabs ist @Published, jede Änderung aktualisiert die Vorschau
//     automatisch ohne eigene Subscription in der View.
//   • Ein einzelnes lokales WebKit-Dokument statt vieler SwiftUI-Textblöcke,
//     damit Auswahl über Absätze hinweg funktioniert und ⌘C echtes
//     Rich-Text liefert.
//   • Klick in den Text springt im Editor an die zugehörige Quellzeile.
//     Die dafür nötigen Zeilenmarken entstehen beim Rendern
//     (siehe `MarkdownSourceMarkers`).
//
// Historie: Bis v1.25 gab es zusätzlich ein separates Vorschau-FENSTER.
// Es war zuletzt ohne Aufrufer (kein Menüeintrag, kein Shortcut) und wurde
// von der integrierten Vorschau vollständig abgelöst.

import AppKit
import Darwin
import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions

// MARK: - SwiftUI-Ansicht

/// Inhaltsansicht der Markdown-Vorschau neben dem Editor.
///
/// Beobachtet den `Workspace` als ObservedObject — jede Änderung an
/// `workspace.tabs` oder `workspace.activeTabID` löst ein automatisches
/// Neuzeichnen aus. Das schließt Live-Aktualisierung beim Tippen ein,
/// da `EditorTab.content` über `tabs` @Published ist.
///
/// - Ist der aktive Tab eine Markdown-Datei (.md / .markdown): Vorschau.
/// - Ist er es nicht: freundlicher Platzhalter.
struct MarkdownPreviewView: View {

    /// Workspace wird NICHT als @EnvironmentObject erwartet, sondern direkt
    /// übergeben — `EditorView` reicht den konkreten Workspace herein,
    /// unabhängig davon ob er im SwiftUI-Environment registriert ist.
    @ObservedObject var workspace: Workspace
    @AppStorage(DocumentZoom.defaultsKey) private var documentZoomLevel = 0
    @AppStorage(PreviewFonts.defaultsKey) private var previewFontName = PreviewFonts.systemName
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let tab = workspace.activeTab, isMarkdown(tab.title) {
                // Markdown-Tab: Vorschau mit GFM-Thema.
                markdownContent(tab: tab)
            } else {
                // Kein Markdown-Tab aktiv: freundlicher Platzhalter.
                placeholderView
            }
        }
        // Hintergrundfarbe für den äußeren Rahmen. Die eingebettete HTML-
        // Vorschau erhält dieselben neutralen Hell-/Dunkelwerte in ihrem CSS.
        // LESSONS-LEARNED F.6b: kein Gray-Colorspace — Theme.surfaceRaised
        // ist als sRGB-Wert definiert, passt also für beide Appearance-Modi.
        .background(Theme.surfaceRaised)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Teilansichten

    /// Die eigentliche Markdown-Vorschau mit Scrollbarkeit.
    /// Bei leerem Tab-Inhalt zeigt sie statt `Markdown("")` einen
    /// informativen Platzhalter im gleichen Stil wie `placeholderView`.
    @ViewBuilder
    private func markdownContent(tab: EditorTab) -> some View {
        if tab.content.isEmpty {
            // Leere .md-Datei: Platzhalter statt leerem ScrollView.
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .fastraFont(size: 40)
                    .foregroundColor(Theme.textSecondary)
                Text("Diese Markdown-Datei ist noch leer.")
                    .fastraFont(.ui)
                    .foregroundColor(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceRaised)
        } else {
            // Ein einzelnes lokales WebKit-Dokument statt vieler separater
            // SwiftUI-Textblöcke: Auswahl kann über Absätze hinweg gezogen
            // werden und ⌘C schreibt Klartext plus semantisches HTML.
            MarkdownRichTextView(
                markdown: tab.content,
                documentURL: tab.url,
                fontName: previewFontName,
                fontSize: previewFontSize,
                darkMode: colorScheme == .dark,
                workspace: workspace
            )
            .background(Theme.surfaceRaised)
        }
    }

    private var previewFontSize: CGFloat {
        14 * DocumentZoom.scale(for: documentZoomLevel)
    }

    /// Platzhalter, wenn der aktive Tab keine Markdown-Datei ist.
    private var placeholderView: some View {
        VStack(spacing: 12) {
            // SF-Symbol als visuellen Anker — kein Emoji.
            Image(systemName: "doc.text")
                .fastraFont(size: 40)
                // textSecondary: sRGB-Wert aus Theme.swift, kein Gray-Colorspace.
                .foregroundColor(Theme.textSecondary)
            Text("Die Vorschau zeigt Markdown-Dateien (.md)")
                .fastraFont(.ui)
                .foregroundColor(Theme.textSecondary)
            Text("Der aktive Tab ist keine Markdown-Datei.")
                .fastraFont(.small)
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surfaceRaised)
    }

    // MARK: Hilfsmethoden

    /// Prüft, ob ein Dateiname als Markdown gilt.
    /// Erkannte Endungen: .md und .markdown (Groß-/Kleinschreibung egal).
    private func isMarkdown(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}

// MARK: - Auswählbare Rich-Text-Vorschau

/// Erzeugt aus GFM-Markdown ein vollständiges, lokal gerendertes HTML-Dokument.
/// Der Copy-Handler schreibt sowohl Klartext als auch das semantische HTML der
/// Auswahl; Rich-Text-Ziele behalten dadurch Überschriften, Fettung und Listen.
enum MarkdownRichText {
    static func htmlDocument(markdown: String,
                             documentURL: URL? = nil,
                             fontName: String,
                             fontSize: CGFloat,
                             darkMode: Bool) -> String {
        let fragment = renderedFragment(markdown: markdown, documentURL: documentURL)
        let bodyColor = darkMode ? "#F2F2F2" : "#363636"
        let secondary = darkMode ? "#A8A8A8" : "#737373"
        let surface = darkMode ? "#171717" : "#FFFFFF"
        let control = darkMode ? "#333333" : "#ECECEC"
        let border = darkMode ? "#484848" : "#D7D7D7"
        let link = darkMode ? "#8BB7F2" : "#3F69A8"
        let cssFont = fontName == PreviewFonts.systemName
            ? "-apple-system, BlinkMacSystemFont, sans-serif"
            : "'\(cssEscaped(fontName))', -apple-system, sans-serif"

        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: fastra-preview:; style-src 'unsafe-inline' fastra-preview:; script-src 'unsafe-inline' fastra-preview:; connect-src 'none'; media-src 'none'; frame-src 'none'">
        <link rel="stylesheet" href="fastra-preview://resource/highlight.css">
        <style>
        body { margin: 0; padding: 20px; box-sizing: border-box;
               color: \(bodyColor); background: \(surface);
               font-family: \(cssFont); font-size: \(fontSize)px; line-height: 1.55; }
        h1, h2, h3, h4, h5, h6 { color: \(bodyColor); margin: 1.1em 0 0.45em; }
        h1 { font-size: 2em; } h2 { font-size: 1.55em; } h3 { font-size: 1.25em; }
        p, ul, ol, pre, blockquote, table { margin: 0.65em 0; }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
               background: \(control); border-radius: 4px; padding: 0.12em 0.3em; }
        pre { background: \(control); border-radius: 8px; padding: 0.85em; }
        pre code { padding: 0; background: transparent; }
        blockquote { color: \(secondary); border-left: 3px solid \(border);
                     margin-left: 0; padding-left: 0.9em; }
        table { border-collapse: collapse; } th, td { border: 1px solid \(border);
                padding: 0.35em 0.6em; } a { color: \(link); }
        img { display: block; max-width: 100%; height: auto; margin: 0.8em 0;
              border-radius: 6px; }
        .math-inline math { font-size: 1.05em; }
        .math-block { max-width: 100%; margin: 1em 0; overflow-x: auto;
                      text-align: center; }
        .mermaid-render { max-width: 100%; margin: 1em 0; overflow-x: auto;
                          text-align: center; }
        .mermaid-render svg { max-width: 100%; height: auto; }
        pre.mermaid-error::before { content: attr(data-error); display: block;
                                    color: \(secondary); margin-bottom: 0.55em; }
        hr { border: 0; border-top: 1px solid \(border); }
        </style>
        <script src="fastra-preview://resource/katex.js"></script>
        <script src="fastra-preview://resource/highlight.js"></script>
        <script src="fastra-preview://resource/mermaid.js"></script>
        <script>
        const mermaidError = "\(javascriptEscaped(L10n.string("Diagramm konnte nicht gerendert werden.")))";
        if (window.mermaid) {
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            htmlLabels: false,
            maxTextSize: 100000,
            maxEdges: 500,
            theme: '\(darkMode ? "dark" : "default")'
          });
        }

        async function enhanceMarkdown(root) {
          if (window.katex) {
            root.querySelectorAll('[data-tex]:not([data-rendered])').forEach(element => {
              try {
                katex.render(element.getAttribute('data-tex'), element, {
                  displayMode: element.classList.contains('math-block'),
                  output: 'mathml',
                  throwOnError: false,
                  trust: false
                });
              } catch (_) {
                element.textContent = element.getAttribute('data-tex');
              }
              element.dataset.rendered = '1';
            });
          }

          root.querySelectorAll('pre > code').forEach(code => {
            if (code.classList.contains('language-mermaid')) return;
            if (window.hljs && !code.dataset.highlighted) {
              try { hljs.highlightElement(code); } catch (_) {}
            }
          });

          if (window.mermaid) {
            const blocks = Array.from(
              root.querySelectorAll('pre > code.language-mermaid:not([data-rendered])')
            );
            for (const code of blocks) {
              code.dataset.rendered = '1';
              const pre = code.parentElement;
              const diagram = document.createElement('div');
              diagram.className = 'mermaid mermaid-render';
              diagram.textContent = code.textContent;
              pre.before(diagram);
              try {
                await mermaid.run({ nodes: [diagram], suppressErrors: true });
                if (!diagram.querySelector('svg')) throw new Error('render failed');
                pre.remove();
              } catch (_) {
                diagram.remove();
                pre.classList.add('mermaid-error');
                pre.dataset.error = mermaidError;
              }
            }
          }
        }

        document.addEventListener('copy', function(event) {
          const selection = window.getSelection();
          if (!selection || selection.rangeCount === 0) return;
          const rich = document.createElement('div');
          for (let index = 0; index < selection.rangeCount; index++) {
            rich.appendChild(selection.getRangeAt(index).cloneContents());
          }
          // Die Quellzeilen sind Fastra-Interna und haben in fremden
          // Dokumenten nichts verloren.
          rich.querySelectorAll('[\(MarkdownSourceMarkers.attribute)]').forEach(
            element => element.removeAttribute('\(MarkdownSourceMarkers.attribute)')
          );
          const plain = selection.toString();
          const html = rich.innerHTML;
          event.clipboardData.setData('text/plain', plain);
          event.clipboardData.setData('text/html', html);
          // WebKit reicht selbst gesetztes HTML nicht an jedes native Ziel
          // weiter (Pages sah deshalb nur Klartext). Der native Handler ergänzt
          // das macOS-Pasteboard synchron um HTML und echtes RTF.
          if (window.webkit?.messageHandlers?.markdownCopy) {
            window.webkit.messageHandlers.markdownCopy.postMessage({ plain, html });
          }
          event.preventDefault();
        });

        // Klick in den Text: zugehörige Stelle im Editor anspringen.
        //
        // Der angeklickte Block kennt seine erste Quellzeile. Innerhalb des
        // Blocks kommt die Feinauflösung daher, dass jeder Zeilenumbruch des
        // Quelltextes im gerenderten Text als echtes Newline steht — sie
        // müssen zwischen Blockanfang und Klickstelle nur gezählt werden.
        function caretFromPoint(x, y) {
          // WebKit kennt caretRangeFromPoint; die Standardvariante steht als
          // Rückfallebene daneben.
          if (document.caretRangeFromPoint) {
            const range = document.caretRangeFromPoint(x, y);
            if (range) return { node: range.endContainer, offset: range.endOffset };
          }
          if (document.caretPositionFromPoint) {
            const position = document.caretPositionFromPoint(x, y);
            if (position) return { node: position.offsetNode, offset: position.offset };
          }
          return null;
        }

        function sourcePositionForEvent(event) {
          const target = event.target;
          if (!target || !target.closest) return null;
          const block = target.closest('[\(MarkdownSourceMarkers.attribute)]');
          if (!block) return null;
          const base = parseInt(
            block.getAttribute('\(MarkdownSourceMarkers.attribute)'), 10
          );
          if (!Number.isFinite(base)) return null;

          const caret = caretFromPoint(event.clientX, event.clientY);
          if (!caret || !block.contains(caret.node)) return { line: base, column: 1 };

          const range = document.createRange();
          range.selectNodeContents(block);
          try {
            range.setEnd(caret.node, caret.offset);
          } catch (_) {
            return { line: base, column: 1 };
          }
          const before = range.toString();
          const lastBreak = before.lastIndexOf('\\n');
          const newlines = (before.match(/\\n/g) || []).length;
          // Die Spalte ist eine NÄHERUNG: Im gerenderten Text fehlen Markup-
          // Zeichen (**, [] usw.), er ist also kürzer als der Quelltext. Für
          // Fließtext trifft sie gut, sonst landet der Cursor etwas zu früh in
          // der richtigen Zeile. Der Editor klemmt zu große Werte selbst ab.
          const column = before.length - lastBreak;
          return { line: base + newlines, column: Math.max(1, column) };
        }

        document.addEventListener('click', function(event) {
          // Nur ein echter Klick, nicht das Ende einer Textauswahl.
          const selection = window.getSelection();
          if (selection && !selection.isCollapsed) return;
          // Links behalten ihr eigenes Verhalten (Öffnen im Standardbrowser).
          if (event.target && event.target.closest && event.target.closest('a')) return;
          const position = sourcePositionForEvent(event);
          if (!position) return;
          if (window.webkit?.messageHandlers?.markdownJump) {
            window.webkit.messageHandlers.markdownJump.postMessage(position);
          }
        });
        window.addEventListener('DOMContentLoaded', () => enhanceMarkdown(document.body));
        </script></head><body>\(fragment.html)</body></html>
        """
    }

    static func htmlFragment(markdown: String) -> String {
        renderedFragment(markdown: markdown, documentURL: nil).html
    }

    static func renderedFragment(markdown: String,
                                 documentURL: URL?) -> MarkdownRenderedFragment {
        let math = MarkdownMath.extract(from: markdown)
        // cmark rendert Erweiterungen nur, wenn dieselbe Extension-Liste auch
        // an den HTML-Renderer gereicht wird. Fehlt sie dort, würden Tabellen
        // trotz korrektem Parsing zu unstrukturiertem Fließtext.
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else {
            return MarkdownRenderedFragment(html: escapedPlainText(markdown), imageURLs: [:])
        }
        defer { cmark_parser_free(parser) }

        for extensionName in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            extensionName.withCString { name in
                if let syntaxExtension = cmark_find_syntax_extension(name) {
                    cmark_parser_attach_syntax_extension(parser, syntaxExtension)
                }
            }
        }

        math.markdown.withCString { bytes in
            cmark_parser_feed(parser, bytes, math.markdown.utf8.count)
        }
        guard let document = cmark_parser_finish(parser) else {
            return MarkdownRenderedFragment(html: escapedPlainText(markdown), imageURLs: [:])
        }
        defer { cmark_node_free(document) }

        // Codeblock-Inhaltszeilen aus dem Baum lesen, solange er noch steht.
        // CMARK_OPT_SOURCEPOS liefert danach die Blockpositionen im HTML.
        let codeBlockLines = MarkdownSourceMarkers.codeBlockContentLines(
            document: document,
            extraction: math
        )

        let extensions = cmark_parser_get_syntax_extensions(parser)
        guard let rendered = cmark_render_html(document, CMARK_OPT_SOURCEPOS, extensions) else {
            return MarkdownRenderedFragment(html: escapedPlainText(markdown), imageURLs: [:])
        }
        defer { free(rendered) }

        let positioned = MarkdownSourceMarkers.rewriteBlockPositions(
            in: String(cString: rendered),
            extraction: math,
            codeBlockLines: codeBlockLines
        )
        let withMath = math.insertingHTML(into: positioned)
        return MarkdownImages.resolve(in: withMath, relativeTo: documentURL)
    }

    /// Fehler-Fallback ohne HTML-Injektion. Normalerweise wird dieser Pfad nur
    /// bei einer Speicherknappheit im C-Parser erreicht.
    private static func escapedPlainText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>\n")
    }

    /// Ein Fontname kommt aus der installierten Fontliste, wird für CSS aber
    /// trotzdem defensiv escaped, damit Apostrophe und Backslashes harmlos sind.
    private static func cssEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private static func javascriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

/// Schreibt eine Markdown-Auswahl in allen für native Mac-Programme relevanten
/// Darstellungen. Pages bevorzugt RTF, Browser und Web-Editoren können HTML
/// verwenden, reine Textziele fallen weiterhin sauber auf Klartext zurück.
enum MarkdownPasteboard {
    @discardableResult
    static func write(plain: String,
                      htmlFragment: String,
                      to pasteboard: NSPasteboard = .general) -> Bool {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head>
        <body>\(htmlFragment)</body></html>
        """
        guard let htmlData = html.data(using: .utf8) else { return false }

        let attributed = try? NSAttributedString(
            data: htmlData,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        let rtf = attributed?.rtf(
            from: NSRange(location: 0, length: attributed?.length ?? 0),
            documentAttributes: [:]
        )

        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.html, .string]
        if rtf != nil { types.insert(.rtf, at: 0) }
        pasteboard.declareTypes(types, owner: nil)
        if let rtf { pasteboard.setData(rtf, forType: .rtf) }
        pasteboard.setString(html, forType: .html)
        pasteboard.setString(plain, forType: .string)
        return true
    }
}

/// SwiftUI-Brücke zu WebKit. Der Browser-Unterbau ist hier bewusst passend:
/// Er kann GFM-Tabellen und Listen layouttreu darstellen, Text über mehrere
/// Blöcke markieren und beim nativen ⌘C HTML plus Klartext bereitstellen.
private struct MarkdownRichTextView: NSViewRepresentable {
    let markdown: String
    let documentURL: URL?
    let fontName: String
    let fontSize: CGFloat
    let darkMode: Bool
    /// Ziel für den Klick-Sprung. Der Coordinator lebt länger als diese
    /// Struktur, deshalb wird der Workspace bei jedem Update neu gesetzt.
    let workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Keine Cookies, kein Cache und keine persistente Website-Historie:
        // die Vorschau bleibt ein lokaler Dokument-Renderer.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "markdownCopy")
        configuration.userContentController.add(context.coordinator, name: "markdownJump")
        configuration.setURLSchemeHandler(
            context.coordinator.assetHandler,
            forURLScheme: MarkdownPreviewAssets.scheme
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = darkMode
            ? NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        update(webView: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        update(webView: webView, coordinator: context.coordinator)
    }

    private func update(webView: WKWebView, coordinator: Coordinator) {
        coordinator.workspace = workspace
        let styleIdentity = "\(darkMode)|\(fontName)|\(fontSize)|\(documentURL?.path ?? "")"
        if coordinator.styleIdentity != styleIdentity {
            coordinator.styleIdentity = styleIdentity
            coordinator.markdown = markdown
            coordinator.isReady = false
            let fragment = MarkdownRichText.renderedFragment(
                markdown: markdown,
                documentURL: documentURL
            )
            coordinator.assetHandler.setImageURLs(fragment.imageURLs)
            let document = MarkdownRichText.htmlDocument(
                markdown: markdown,
                documentURL: documentURL,
                fontName: fontName,
                fontSize: fontSize,
                darkMode: darkMode
            )
            webView.loadHTMLString(document, baseURL: nil)
            return
        }

        guard coordinator.markdown != markdown else { return }
        coordinator.markdown = markdown
        let fragment = MarkdownRichText.renderedFragment(
            markdown: markdown,
            documentURL: documentURL
        )
        coordinator.assetHandler.setImageURLs(fragment.imageURLs)
        guard coordinator.isReady else {
            coordinator.pendingFragment = fragment
            return
        }
        coordinator.replaceBody(with: fragment, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var styleIdentity = ""
        var markdown = ""
        var isReady = false
        var pendingFragment: MarkdownRenderedFragment?
        let assetHandler = MarkdownPreviewSchemeHandler()
        // Schwach: Der Workspace gehört der Dokumentszene, nicht der Vorschau.
        weak var workspace: Workspace?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any] else { return }
            switch message.name {
            case "markdownCopy":
                guard let plain = payload["plain"] as? String,
                      let html = payload["html"] as? String else { return }
                MarkdownPasteboard.write(plain: plain, htmlFragment: html)
            case "markdownJump":
                guard let line = payload["line"] as? Int else { return }
                jump(toLine: line, column: payload["column"] as? Int ?? 1)
            default:
                return
            }
        }

        /// Setzt Cursor und Sichtbereich des Editors auf die angeklickte Stelle.
        ///
        /// Adressiert wird über Zeile/Spalte statt über einen absoluten Offset.
        /// Begründung siehe `NotificationCenter.postMatchJump`: Absolute Ranges
        /// driften zwischen Vorschau-Inhalt und Editor-Speicher, sobald Encoding
        /// oder Zeilenenden normalisiert werden. Zu große Spalten klemmt der
        /// Empfänger selbst ab — die aus dem HTML geschätzte Spalte darf also
        /// ruhig etwas danebenliegen.
        private func jump(toLine line: Int, column: Int) {
            guard let workspace else { return }
            NotificationCenter.default.post(
                name: .fastraJumpToRange,
                object: workspace,
                userInfo: [
                    "startLine": line, "startColumn": column,
                    "endLine": line, "endColumn": column
                ]
            )
            // Ohne Fokuswechsel bliebe die Tastatur in der Vorschau, und der
            // Nutzer müsste nach dem Klick noch einmal in den Editor klicken.
            EditorView.focusActiveEditor(in: workspace)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let pendingFragment {
                self.pendingFragment = nil
                replaceBody(with: pendingFragment.html, in: webView)
            }
        }

        /// Nur der Body wird live ersetzt. Scrollposition und Auswahl bleiben
        /// so stabiler als bei einem vollständigen Seiten-Reload pro Tastendruck.
        func replaceBody(with fragment: MarkdownRenderedFragment, in webView: WKWebView) {
            replaceBody(with: fragment.html, in: webView)
        }

        private func replaceBody(with fragment: String, in webView: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: [fragment]),
                  let json = String(data: data, encoding: .utf8) else { return }
            let script = """
            (async () => {
              const x = window.scrollX, y = window.scrollY;
              window.markdownGeneration = (window.markdownGeneration || 0) + 1;
              const generation = window.markdownGeneration;
              document.body.innerHTML = \(json)[0];
              await enhanceMarkdown(document.body);
              if (generation === window.markdownGeneration) window.scrollTo(x, y);
            })();
            """
            webView.evaluateJavaScript(script)
        }

        /// Ein bewusster Link-Klick darf den Standardbrowser öffnen; die lokale
        /// Vorschau selbst navigiert nie von ihrem Dokument weg.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
