import Foundation

/// The last five things read aloud, kept on this Mac so they can be played
/// again even after they've left the clipboard.
final class History: ObservableObject {
    static let shared = History()
    static let limit = 5

    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        let title: String
        let text: String
        var date: Date
    }

    @Published private(set) var items: [Item] = []

    private let url = SpeechEngine.supportDirectory.appendingPathComponent("history.json")

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(title: String, text: String) {
        var next = items.filter { $0.text != text }
        next.insert(Item(title: title, text: text, date: Date()), at: 0)
        items = Array(next.prefix(History.limit))
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: SpeechEngine.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
    }
}
