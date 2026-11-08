import AppKit
import NaturalLanguage

/// One piece of speech: usually a sentence. `range` is where it sits in the
/// displayed text. For normal text the spoken words are exactly that text, so
/// the engine's word offsets map straight onto the page.
struct Segment {
    let index: Int
    let range: NSRange
    let speech: String
    let pause: Double
    let isCode: Bool
    /// Places where the speech differs from the page, such as links.
    var replacements: [SpokenText.Replacement] = []

    /// Where a word of the speech sits on the page, relative to `range`.
    func pageRange(start: Int, end: Int) -> NSRange {
        var delta = 0
        for r in replacements {
            if start >= r.speech.location && start < NSMaxRange(r.speech) { return r.page }
            guard start >= NSMaxRange(r.speech) else { break }
            delta = NSMaxRange(r.page) - NSMaxRange(r.speech)
        }
        return NSRange(location: start + delta, length: max(0, end - start))
    }
}

/// Makes text sound natural: a link is spoken as its site name ("github dot com"),
/// with no https, www, slashes or path.
enum SpokenText {
    struct Replacement {
        let speech: NSRange
        let page: NSRange
    }

    private static let link = try! NSRegularExpression(
        pattern: #"(?i)(?<![@\w.-])(?:(?:https?|ftp)://[^\s<>()\[\]"'`]+|www\.[^\s<>()\[\]"'`]+|[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|ai|dev|app|co|edu|gov|au|uk|nz|ca|me|tv)\b(?:/[^\s<>()\[\]"'`]*)?)"#)

    /// Joins sentences that were split inside a link, such as at the "?" in "a.com/b?c=1".
    static func keepingLinksWhole(_ ranges: [NSRange], in text: NSString) -> [NSRange] {
        guard let first = ranges.first, let last = ranges.last else { return ranges }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let links = link.matches(in: text as String, range: span).map(\.range)
        var out: [NSRange] = []
        for r in ranges {
            if let prev = out.last, links.contains(where: { $0.location < r.location && NSMaxRange($0) > r.location }) {
                out[out.count - 1] = NSRange(location: prev.location, length: NSMaxRange(r) - prev.location)
            } else {
                out.append(r)
            }
        }
        return out
    }

    static func make(_ text: String) -> (speech: String, replacements: [Replacement]) {
        let ns = text as NSString
        var out = ""
        var reps: [Replacement] = []
        var cursor = 0
        for m in link.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            // Sentence punctuation after a link isn't part of it.
            while r.length > 0, let u = UnicodeScalar(ns.character(at: NSMaxRange(r) - 1)),
                  CharacterSet(charactersIn: ".,;:!?").contains(u) {
                r.length -= 1
            }
            guard r.length > 0, let name = siteName(ns.substring(with: r)) else { continue }
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let start = (out as NSString).length
            out += name
            reps.append(Replacement(speech: NSRange(location: start, length: (name as NSString).length), page: r))
            cursor = NSMaxRange(r)
        }
        out += ns.substring(from: cursor)
        return (out, reps)
    }

    /// "https://www.docs.example.com/a/b?c=1" -> "docs dot example dot com"
    static func siteName(_ link: String) -> String? {
        var s = link.lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        s = String(s.prefix { !"/?#".contains($0) })
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        s = String(s.prefix { $0 != ":" })
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard !s.isEmpty else { return nil }
        if s == "localhost" || s == "127.0.0.1" { return "a local address" }
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return "a numeric address" }
        return s.split(separator: ".").joined(separator: " dot ")
    }
}

/// Turns copied text (usually Markdown from Claude) into a nicely styled page
/// plus the list of segments to speak.
final class ReadingDocument {
    let text: NSAttributedString
    let segments: [Segment]
    let title: String
    var plainText: String { text.string }

    private enum BlockKind { case paragraph, heading(Int), bullet, numbered(String), quote, code, table }
    private struct Block { let kind: BlockKind; let lines: [String] }

    /// Longest piece of speech, in characters. The first pieces are short so
    /// talking starts quickly; each later one can be made while the one before plays.
    private static func maxLength(forSegment n: Int) -> Int {
        [70, 110, 150][safe: n] ?? 180
    }

    init(markdown raw: String) {
        let source = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let blocks = ReadingDocument.parseBlocks(source)
        let out = NSMutableAttributedString()
        var segs: [Segment] = []

        for (bi, block) in blocks.enumerated() {
            if bi > 0 { out.append(NSAttributedString(string: "\n", attributes: Style.body)) }
            let start = out.length
            switch block.kind {
            case .code:
                let code = block.lines.joined(separator: "\n")
                let shown = code.isEmpty ? " " : code
                out.append(NSAttributedString(string: shown, attributes: Style.codeBlock))
                let range = NSRange(location: start, length: out.length - start)
                segs.append(Segment(index: segs.count, range: range, speech: "Code snippet.", pause: 0.35, isCode: true))
            case .heading(let level):
                let (s, _) = ReadingDocument.inline(block.lines.joined(separator: " "), base: Style.heading(level))
                out.append(s)
                ReadingDocument.addSentences(in: out, from: start, pause: 0.45, into: &segs)
            case .bullet, .numbered:
                let marker: String
                if case .numbered(let n) = block.kind { marker = "\(n).\t" } else { marker = "•\t" }
                out.append(NSAttributedString(string: marker, attributes: Style.listMarker))
                let bodyStart = out.length
                let (s, _) = ReadingDocument.inline(block.lines.joined(separator: " "), base: Style.listItem)
                out.append(s)
                // The marker belongs to the paragraph style, the words are spoken.
                out.addAttribute(.paragraphStyle, value: Style.listParagraph, range: NSRange(location: start, length: out.length - start))
                ReadingDocument.addSentences(in: out, from: bodyStart, pause: 0.3, into: &segs)
            case .quote:
                let (s, _) = ReadingDocument.inline(block.lines.joined(separator: " "), base: Style.quote)
                out.append(s)
                ReadingDocument.addSentences(in: out, from: start, pause: 0.35, into: &segs)
            case .table:
                let rows = block.lines.compactMap(ReadingDocument.tableCells)
                for (ri, cells) in rows.enumerated() {
                    if ri > 0 { out.append(NSAttributedString(string: "\n", attributes: Style.table)) }
                    let rowStart = out.length
                    let (s, _) = ReadingDocument.inline(cells.joined(separator: ", "), base: ri == 0 ? Style.tableHeader : Style.table)
                    out.append(s)
                    ReadingDocument.addSentences(in: out, from: rowStart, pause: 0.25, into: &segs)
                }
            case .paragraph:
                let (s, _) = ReadingDocument.inline(block.lines.joined(separator: " "), base: Style.body)
                out.append(s)
                ReadingDocument.addSentences(in: out, from: start, pause: 0.35, into: &segs)
            }
        }
        text = out
        segments = segs
        let firstLine = out.string.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "Reading"
        title = firstLine.count > 60 ? String(firstLine.prefix(57)) + "…" : (firstLine.isEmpty ? "Reading" : firstLine)
    }

    // MARK: - Blocks

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var table: [String] = []
        var code: [String]? = nil
        var fence = ""

        func flushPara() { if !para.isEmpty { blocks.append(Block(kind: .paragraph, lines: para)); para = [] } }
        func flushTable() { if !table.isEmpty { blocks.append(Block(kind: .table, lines: table)); table = [] } }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var c = code {
                if trimmed.hasPrefix(fence) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: fence.prefix(1) == "`" ? "`" : "~")).isEmpty {
                    blocks.append(Block(kind: .code, lines: c))
                    code = nil
                } else {
                    c.append(line)
                    code = c
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushPara(); flushTable()
                fence = String(trimmed.prefix(3))
                code = []
                continue
            }
            if trimmed.isEmpty { flushPara(); flushTable(); continue }
            if trimmed.hasPrefix("|") {
                flushPara()
                table.append(trimmed)
                continue
            } else {
                flushTable()
            }
            if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushPara()
                blocks.append(Block(kind: .heading(m.1.count), lines: [String(m.2).replacingOccurrences(of: #"\s*#+\s*$"#, with: "", options: .regularExpression)]))
                continue
            }
            if trimmed.wholeMatch(of: /^([-*_])(\s*\1){2,}$/) != nil { flushPara(); continue }
            if let m = trimmed.firstMatch(of: /^[-*+•]\s+(.*)$/) {
                flushPara()
                blocks.append(Block(kind: .bullet, lines: [String(m.1)]))
                continue
            }
            if let m = trimmed.firstMatch(of: /^(\d{1,3})[.)]\s+(.*)$/) {
                flushPara()
                blocks.append(Block(kind: .numbered(String(m.1)), lines: [String(m.2)]))
                continue
            }
            if let m = trimmed.firstMatch(of: /^>\s?(.*)$/) {
                flushPara()
                if case .quote? = blocks.last?.kind, let last = blocks.popLast() {
                    blocks.append(Block(kind: .quote, lines: last.lines + [String(m.1)]))
                } else {
                    blocks.append(Block(kind: .quote, lines: [String(m.1)]))
                }
                continue
            }
            // Each line is its own paragraph. Copied text (and Claude's Markdown)
            // uses a single line break between paragraphs, so joining lines
            // would run separate paragraphs together.
            flushPara()
            para.append(trimmed)
            flushPara()
        }
        if let c = code { blocks.append(Block(kind: .code, lines: c)) }
        flushPara(); flushTable()
        return blocks
    }

    private static func tableCells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.allSatisfy({ $0.isEmpty || $0.wholeMatch(of: /:?-{2,}:?/) != nil }) { return nil }
        return cells.filter { !$0.isEmpty }
    }

    // MARK: - Inline Markdown

    /// Strips **bold**, *italic*, `code` and [links](url), keeping their look.
    private static func inline(_ s: String, base: [NSAttributedString.Key: Any]) -> (NSAttributedString, Int) {
        let out = NSMutableAttributedString()
        let pattern = #"(!\[[^\]]*\]\([^)]*\))|(\[([^\]]+)\]\([^)]*\))|(`([^`]+)`)|(\*\*([^*]+)\*\*)|(__([^_]+)__)|(\*([^*\s][^*]*?)\*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        var cursor = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), attributes: base))
            }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if group(1) != nil {
                // images are skipped
            } else if let t = group(3) {
                var a = base; a[.foregroundColor] = NSColor.linkColor
                out.append(NSAttributedString(string: t, attributes: a))
            } else if let t = group(5) {
                out.append(NSAttributedString(string: t, attributes: Style.inlineCode(base)))
            } else if let t = group(7) ?? group(9) {
                out.append(NSAttributedString(string: t, attributes: Style.withTrait(base, .bold)))
            } else if let t = group(11) {
                out.append(NSAttributedString(string: t, attributes: Style.withTrait(base, .italic)))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base))
        }
        return (out, out.length)
    }

    // MARK: - Sentences

    private static func addSentences(in text: NSMutableAttributedString, from start: Int, pause: Double, into segs: inout [Segment]) {
        let full = text.string as NSString
        let blockRange = NSRange(location: start, length: full.length - start)
        guard blockRange.length > 0 else { return }
        let blockString = full.substring(with: blockRange)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = blockString
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: blockString.startIndex..<blockString.endIndex) { r, _ in
            let nsr = NSRange(r, in: blockString)
            ranges.append(NSRange(location: nsr.location + start, length: nsr.length))
            return true
        }
        if ranges.isEmpty { ranges = [blockRange] }
        ranges = SpokenText.keepingLinksWhole(ranges, in: full)
        var speakable: [NSRange] = []
        for r in ranges {
            var rest: NSRange? = r
            while let current = rest {
                let limit = maxLength(forSegment: segs.count + speakable.count)
                let (piece, remainder) = splitOnce(current, in: full, limit: limit)
                if let t = trim(piece, in: full), full.substring(with: t).rangeOfCharacter(from: .alphanumerics) != nil {
                    speakable.append(t)
                }
                rest = remainder
            }
        }
        for (i, r) in speakable.enumerated() {
            let last = i == speakable.count - 1
            let spoken = SpokenText.make(full.substring(with: r))
            segs.append(Segment(index: segs.count, range: r, speech: spoken.speech,
                                pause: last ? pause : 0.12, isCode: false, replacements: spoken.replacements))
        }
    }

    /// Cuts the first `limit` characters (or fewer) off a sentence, at a comma or
    /// space where possible. Returns the piece and whatever is left.
    private static func splitOnce(_ r: NSRange, in s: NSString, limit: Int) -> (NSRange, NSRange?) {
        guard r.length > limit else { return (r, nil) }
        let window = NSRange(location: r.location, length: limit)
        var cut = NSNotFound
        for sep in ["; ", ", ", " — ", ": ", " "] {
            let found = s.range(of: sep, options: .backwards, range: window)
            if found.location != NSNotFound && found.location > r.location + limit / 3 {
                cut = found.location + found.length
                break
            }
        }
        if cut == NSNotFound {
            // One very long word, such as a link: keep it whole.
            let after = s.range(of: " ", range: NSRange(location: r.location + limit, length: r.length - limit))
            guard after.location != NSNotFound else { return (r, nil) }
            cut = after.location + 1
        }
        return (NSRange(location: r.location, length: cut - r.location),
                NSRange(location: cut, length: r.location + r.length - cut))
    }

    private static func trim(_ r: NSRange, in s: NSString) -> NSRange? {
        var start = r.location, end = r.location + r.length
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(s.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(s.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

// MARK: - Typography

enum Style {
    static let bodySize: CGFloat = 17

    static var bodyParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.32
        p.paragraphSpacing = 18
        return p
    }

    static var body: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph]
    }

    static func heading(_ level: Int) -> [NSAttributedString.Key: Any] {
        let size: CGFloat = level == 1 ? 26 : level == 2 ? 22 : 19
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.15
        p.paragraphSpacingBefore = level <= 2 ? 10 : 6
        p.paragraphSpacing = 10
        return [.font: NSFont.systemFont(ofSize: size, weight: level == 1 ? .bold : .semibold),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }

    static var listParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.28
        p.paragraphSpacing = 10
        p.headIndent = 26
        p.firstLineHeadIndent = 6
        p.tabStops = [NSTextTab(textAlignment: .left, location: 26)]
        p.defaultTabInterval = 26
        return p
    }

    static var listItem: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: NSColor.labelColor, .paragraphStyle: listParagraph]
    }

    static var listMarker: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: bodySize, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: listParagraph]
    }

    static var quote: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.28
        p.paragraphSpacing = 14
        p.headIndent = 18
        p.firstLineHeadIndent = 18
        return [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: bodySize), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
    }

    static var codeBlock: [NSAttributedString.Key: Any] {
        let block = NSTextBlock()
        block.backgroundColor = NSColor.textColor.withAlphaComponent(0.045)
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(14, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .maxY)
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]
        p.lineHeightMultiple = 1.2
        return [.font: NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]
    }

    static var table: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        p.paragraphSpacing = 6
        return [.font: NSFont.systemFont(ofSize: 15.5), .foregroundColor: NSColor.labelColor, .paragraphStyle: p]
    }

    static var tableHeader: [NSAttributedString.Key: Any] {
        var t = table
        t[.font] = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        return t
    }

    static func inlineCode(_ base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var a = base
        let size = (base[.font] as? NSFont)?.pointSize ?? bodySize
        a[.font] = NSFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular)
        a[.backgroundColor] = NSColor.textColor.withAlphaComponent(0.07)
        return a
    }

    static func withTrait(_ base: [NSAttributedString.Key: Any], _ trait: NSFontDescriptor.SymbolicTraits) -> [NSAttributedString.Key: Any] {
        var a = base
        let font = (base[.font] as? NSFont) ?? NSFont.systemFont(ofSize: bodySize)
        if trait == .bold {
            a[.font] = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        } else {
            a[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return a
    }
}
