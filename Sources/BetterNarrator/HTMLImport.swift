import AppKit

/// Turns the rich text an app puts on the clipboard (HTML) into the Markdown
/// that ReadingDocument understands, so headings, lists, paragraphs and code
/// survive when you highlight text in Claude or a web page.
enum HTMLImport {
    static func markdown(fromHTML html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil),
              attr.length > 0 else { return nil }

        let ns = attr.string as NSString
        let bodySize = typicalFontSize(attr)
        var lines: [String] = []
        var inCode = false
        var numbers: [Int: Int] = [:]  // list depth -> next number

        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { sub, range, _, _ in
            let raw = sub ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, range.length > 0 else {
                if inCode { lines.append("") }
                return
            }
            let style = attr.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let lists = style?.textLists ?? []

            if lists.isEmpty && isMonospaced(attr, range) {
                if !inCode { lines.append("```"); inCode = true }
                lines.append(raw)
                return
            }
            if inCode { lines.append("```"); inCode = false }

            if !lists.isEmpty {
                // Imported list items start with "\t•\t" or "\t1.\t"; drop that marker.
                let body = inline(attr, range).replacingOccurrences(
                    of: #"^\s*([•◦▪︎▪\-–·]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                let depth = lists.count - 1
                let indent = String(repeating: "  ", count: depth)
                let ordered = lists.last?.markerFormat.rawValue.contains("decimal") == true
                if ordered {
                    let n = numbers[depth] ?? 1
                    numbers[depth] = n + 1
                    lines.append("\(indent)\(n). \(body)")
                } else {
                    lines.append("\(indent)- \(body)")
                }
                return
            }
            numbers.removeAll()

            let font = attr.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
            if let font, isBold, font.pointSize >= bodySize * 1.12, trimmed.count < 120 {
                lines.append("")
                lines.append((font.pointSize >= bodySize * 1.5 ? "# " : "## ") + trimmed)
                lines.append("")
                return
            }
            lines.append("")
            lines.append(inline(attr, range))
            lines.append("")
        }
        if inCode { lines.append("```") }
        let text = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Paragraph text with **bold** and `code` kept as Markdown.
    private static func inline(_ attr: NSAttributedString, _ range: NSRange) -> String {
        var out = ""
        attr.enumerateAttribute(.font, in: range) { value, r, _ in
            let piece = (attr.string as NSString).substring(with: r).replacingOccurrences(of: "\n", with: " ")
            let font = value as? NSFont
            if isMono(font), !piece.trimmingCharacters(in: .whitespaces).isEmpty, !piece.contains("`") {
                out += "`\(piece)`"
            } else if font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                      !piece.trimmingCharacters(in: .whitespaces).isEmpty, !piece.contains("*") {
                let lead = piece.prefix { $0 == " " }, trail = String(piece.reversed().prefix { $0 == " " })
                out += "\(lead)**\(piece.trimmingCharacters(in: .whitespaces))**\(trail)"
            } else {
                out += piece
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isMono(_ font: NSFont?) -> Bool {
        guard let font else { return false }
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return true }
        let name = font.fontName.lowercased()
        return ["mono", "menlo", "courier", "consolas", "code"].contains { name.contains($0) }
    }

    private static func isMonospaced(_ attr: NSAttributedString, _ range: NSRange) -> Bool {
        var allMono = true
        attr.enumerateAttribute(.font, in: range) { value, r, stop in
            let piece = (attr.string as NSString).substring(with: r)
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty && !isMono(value as? NSFont) {
                allMono = false
                stop.pointee = true
            }
        }
        return allMono
    }

    /// The font size most of the text uses.
    private static func typicalFontSize(_ attr: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, r, _ in
            if let f = value as? NSFont { counts[f.pointSize.rounded(), default: 0] += r.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 13
    }
}
