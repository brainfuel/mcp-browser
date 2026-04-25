//
//  HistoryStore.swift
//  MCP Browser
//

import Foundation
import Observation

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: String
    var visitedAt: Date
    /// First ~8 KB of `document.body.innerText` captured when the page
    /// finished loading. Used by the history search field to do
    /// full-text matching across saved pages. Optional so older
    /// entries without a snippet still decode cleanly.
    var snippet: String?

    init(id: UUID = UUID(), title: String, url: String, visitedAt: Date = .now, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
        self.snippet = snippet
    }
}

@MainActor
@Observable
final class HistoryStore {
    /// Newest first. Capped to avoid the file growing unbounded.
    private(set) var entries: [HistoryEntry] = []
    private let fileURL = PersistentStore.url(for: "history.json")
    private let maxEntries = 5_000

    init() {
        if let loaded: [HistoryEntry] = PersistentStore.load([HistoryEntry].self, from: fileURL) {
            entries = loaded
        }
    }

    /// Records a visit. Collapses consecutive duplicates so reload
    /// storms don't swamp the list.
    func record(title: String, url: String) {
        guard !url.isEmpty else { return }
        if let first = entries.first, first.url == url {
            // Same page twice in a row — just refresh the timestamp/title.
            entries[0].visitedAt = .now
            if !title.isEmpty { entries[0].title = title }
        } else {
            entries.insert(HistoryEntry(title: title, url: url), at: 0)
            if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        }
        persist()
    }

    /// Attach or replace a page-text snippet for the most recent entry
    /// matching `url`. Called once `document.body.innerText` is
    /// available, typically shortly after `record`.
    func updateSnippet(url: String, snippet: String) {
        guard let idx = entries.firstIndex(where: { $0.url == url }) else { return }
        let trimmed = String(snippet.prefix(8_000))
        if entries[idx].snippet == trimmed { return }
        entries[idx].snippet = trimmed
        persist()
    }

    /// Full-text match across title, url, and snippet. Case-insensitive,
    /// all terms must appear (AND). Empty query returns all entries.
    func search(_ query: String) -> [HistoryEntry] {
        let terms = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        if terms.isEmpty { return entries }
        return entries.filter { entry in
            let hay = (entry.title + " " + entry.url + " " + (entry.snippet ?? "")).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    func remove(id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        PersistentStore.save(entries, to: fileURL)
    }
}
