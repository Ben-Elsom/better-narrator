import Foundation

/// Claude's Copy button copies a whole turn: the progress notes Claude writes
/// between tool calls as well as its final answer. Claude Code saves every
/// session on this Mac (`~/.claude/projects/<project>/<session>.jsonl`) with
/// each piece of text and each tool call stored separately, so a copy can be
/// matched to its turn there and cut down to the text after the last tool call.
///
/// Anything that doesn't clearly match a whole turn (other apps, Claude chat,
/// a highlight of part of a reply, a copy that is already just the answer) is
/// left exactly as it was.
enum ClaudeTranscript {
    /// How many of the most recently changed session files to search.
    private static let filesToSearch = 8
    /// How many letters and digits from each end of a piece of text are used to find it.
    private static let probe = 80

    private struct Turn {
        var earlier: [String] = []   // text before the last tool call
        var answer: [String] = []    // text after it
        var sawTool = false

        mutating func addText(_ t: String) { if sawTool { answer.append(t) } else { earlier.append(t) } }
        mutating func addTool() {
            // Text written before this tool call is progress, not the answer.
            earlier += answer
            answer = []
            sawTool = true
        }
        var isCandidate: Bool { sawTool && !answer.isEmpty && !earlier.isEmpty }
    }

    /// The final answer if `copied` is a whole Claude Code turn, otherwise nil.
    static func finalAnswer(for copied: String) -> String? {
        let start = Date()
        let copyKey = key(copied)
        guard copyKey.count >= 40 else { return nil }
        let files = recentSessionFiles()
        for file in files {
            let all = turns(in: file)
            for i in all.indices.reversed() where all[i].isCandidate {
                let turn = all[i]
                let answer = turn.answer.joined(separator: "\n\n")
                let previous = i > 0 ? (all[i - 1].earlier + all[i - 1].answer).last : nil
                if matches(copyKey: copyKey, earlier: turn.earlier, answer: answer, previous: previous) {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    Log.info("Claude copy matched \(file.lastPathComponent): read only the final answer (\(copied.count) → \(answer.count) chars, \(ms) ms)")
                    return answer
                }
            }
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        Log.info("copy didn't match a Claude Code turn in the \(files.count) newest sessions, reading all of it (\(ms) ms)")
        return nil
    }

    // MARK: - Matching

    /// The copy must hold the whole answer (its start and its end), with some of
    /// the turn's earlier text before it. So a highlight of part of a reply, or a
    /// copy of the answer alone, is never trimmed.
    private static func matches(copyKey: String, earlier: [String], answer: String, previous: String?) -> Bool {
        let a = key(answer)
        guard !a.isEmpty, copyKey.count > a.count else { return false }
        guard let head = copyKey.range(of: String(a.prefix(probe)), options: .backwards),
              let tail = copyKey.range(of: String(a.suffix(probe)), range: head.lowerBound..<copyKey.endIndex)
        else { return false }
        // A copy reaching past this turn (select-all, or a highlight over two
        // replies) is left alone. The progress notes Claude shows don't always
        // match the saved ones word for word, so the start of the copy is
        // checked for the previous reply rather than by length.
        let slack = 300
        let earlierLength = earlier.reduce(0) { $0 + key($1).count }
        guard copyKey.distance(from: tail.upperBound, to: copyKey.endIndex) <= slack,
              copyKey.distance(from: copyKey.startIndex, to: head.lowerBound) <= earlierLength * 3 + 2000
        else { return false }
        let before = copyKey[..<head.lowerBound]
        if let previous {
            let p = key(previous)
            if p.count >= 20 && (before.contains(String(p.prefix(probe))) || before.contains(String(p.suffix(probe)))) { return false }
        }
        return earlier.contains { e in
            let k = key(e)
            return k.count >= 10 && before.contains(String(k.prefix(probe / 2)))
        }
    }

    /// Lower-case letters and digits only, with Markdown link targets removed,
    /// so the copy matches whether it holds Markdown or the text as displayed.
    private static func key(_ s: String) -> String {
        let noLinks = linkTarget.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "]")
        var out = String.UnicodeScalarView()
        for u in noLinks.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(u) { out.append(u) }
        return String(out)
    }
    private static let linkTarget = try! NSRegularExpression(pattern: #"\]\([^)\s]*\)"#)

    // MARK: - Session files

    private static func recentSessionFiles() -> [URL] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for p in projects {
            // Only the sessions themselves; subagent transcripts live in subfolders.
            for f in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: keys)) ?? [] where f.pathExtension == "jsonl" {
                let d = (try? f.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                files.append((f, d))
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(filesToSearch).map(\.0)
    }

    /// Parsed turns per file, kept while the file is unchanged.
    private static var cache: [URL: (stamp: String, turns: [Turn])] = [:]
    private static let lock = NSLock()

    /// Reads the newest sessions ahead of time (when a copy is first seen), so
    /// pressing Read doesn't wait on it.
    static func prepare() {
        DispatchQueue.global(qos: .utility).async { for f in recentSessionFiles() { _ = turns(in: f) } }
    }

    private static func turns(in file: URL) -> [Turn] {
        lock.lock(); defer { lock.unlock() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\((attrs?[.size] as? Int) ?? 0)-\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let c = cache[file], c.stamp == stamp { return c.turns }
        let t = parse(file)
        cache[file] = (stamp, t)
        if cache.count > filesToSearch * 3 { cache = cache.filter { recentSessionFiles().contains($0.key) } }
        return t
    }

    private static let assistantTag = Data(#""type":"assistant""#.utf8)
    private static let userTag = Data(#""type":"user""#.utf8)
    private static let toolResultTag = Data(#""tool_result""#.utf8)

    private static func parse(_ file: URL) -> [Turn] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
        var turns: [Turn] = []
        var current: Turn?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Skip the big entries (tool results, snapshots, progress) without decoding them.
            let isAssistant = line.range(of: assistantTag) != nil
            if !isAssistant && (line.range(of: userTag) == nil || line.range(of: toolResultTag) != nil) { continue }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  (o["isSidechain"] as? Bool) != true,
                  let message = o["message"] as? [String: Any] else { continue }
            if type == "user" {
                guard (o["isMeta"] as? Bool) != true else { continue }
                // A new turn starts at something you typed, not at a tool's result.
                let content = message["content"]
                let typed = content is String
                    || ((content as? [[String: Any]])?.contains { $0["type"] as? String == "text" } ?? false)
                if typed {
                    if let c = current { turns.append(c) }
                    current = Turn()
                }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        current = current ?? Turn()
                        current!.addText(t)
                    }
                case "tool_use":
                    current = current ?? Turn()
                    current!.addTool()
                default: break
                }
            }
        }
        if let c = current { turns.append(c) }
        return turns
    }
}
