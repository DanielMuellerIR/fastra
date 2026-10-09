import AppKit
import Foundation

/// Eine Kopie erhält eigene Bildbytes; interne WebKit-Adressen verlassen die App nicht.
enum MarkdownClipboardImages {
    struct Image {
        let data: Data
        let fileName: String
    }
    struct Transport {
        let html: String
        let attributedHTML: String
        let attachments: [String: Image]
    }
    private static let tags = try! NSRegularExpression(pattern: #"(?i)<img\b(?:[^"'<>]|"[^"]*"|'[^']*')*>"#)
    static let maximumTotalBytes = 64 * 1024 * 1024

    static func prepare(_ html: String, imageURLs: [String: URL], loadImages: Bool) -> Transport {
        let output = NSMutableString(string: html), attributed = NSMutableString(string: html)
        let ns = html as NSString
        var attachments: [String: Image] = [:], loaded: [String: Image] = [:], attempted = Set<String>(), total = 0
        for tag in tags.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let raw = ns.substring(with: tag.range)
            let attributes = MarkdownHTMLAttributes.parse(raw)
            let attribute = attributes.first { $0.name == "src" }
            let valueRange = attribute?.valueRange
            let value = attribute?.value ?? ""
            let url = URL(string: value)
            let token = url?.scheme == MarkdownPreviewAssets.scheme && url?.host == "image" ? url?.lastPathComponent : nil
            var image = token.flatMap { loaded[$0] }
            if image == nil, loadImages, let token, attempted.insert(token).inserted, let file = imageURLs[token],
               MarkdownPreviewAssets.imageMIMEType(for: file) != nil,
               let data = try? MarkdownPreviewAssets.readImageData(file), data.count <= maximumTotalBytes - total {
                image = Image(data: data, fileName: "image.\(file.pathExtension.lowercased())")
                loaded[token] = image
            }
            if let image, image.data.count <= maximumTotalBytes - total, let token, let file = imageURLs[token],
               let mime = MarkdownPreviewAssets.imageMIMEType(for: file), let valueRange {
                total += image.data.count
                let richTag = NSMutableString(string: raw)
                richTag.replaceCharacters(in: valueRange, with: "data:\(mime);base64,\(image.data.base64EncodedString())")
                output.replaceCharacters(in: tag.range, with: richTag as String)
                let placeholder = "FASTRACLIPIMAGE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))END"
                attachments[placeholder] = image
                attributed.replaceCharacters(in: tag.range, with: placeholder)
            } else {
                // Der HTML-Importer darf weder interne Adressen noch fremde URLs laden.
                let alt = attributes.first { $0.name == "alt" }?.value ?? ""
                let escaped = alt.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                output.replaceCharacters(in: tag.range, with: escaped)
                attributed.replaceCharacters(in: tag.range, with: escaped)
            }
        }
        return Transport(html: output as String, attributedHTML: attributed as String, attachments: attachments)
    }

    @MainActor
    static func attributed(_ transport: Transport) -> NSAttributedString? {
        let document = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(transport.attributedHTML)</body></html>"
        guard let data = document.data(using: .utf8),
              let value = try? NSMutableAttributedString(data: data, options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return nil }
        for (placeholder, image) in transport.attachments {
            let range = (value.string as NSString).range(of: placeholder)
            guard range.location != NSNotFound else { continue }
            let attachment = NSTextAttachment()
            attachment.fileWrapper = FileWrapper(regularFileWithContents: image.data)
            attachment.fileWrapper?.preferredFilename = image.fileName
            value.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
        }
        return value
    }
}
