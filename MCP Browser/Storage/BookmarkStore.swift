//
//  BookmarkStore.swift
//  MCP Browser
//
//  Hierarchical bookmark store: bookmarks can live at the root or
//  inside folders, folders can nest, and one folder is designated as
//  the bookmarks-bar root. The bar UI renders that folder's direct
//  children, with subfolders surfacing as cascading menus.
//

import Foundation
import Observation

// MARK: - Models

struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: String
    var parentID: UUID?
    var createdAt: Date

    init(id: UUID = UUID(),
         title: String,
         url: String,
         parentID: UUID? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.url = url
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

struct BookmarkFolder: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         parentID: UUID? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

/// A bookmark or a folder, used to render mixed-content lists like
/// the bookmarks bar's children.
enum BookmarkNode: Identifiable, Hashable {
    case bookmark(Bookmark)
    case folder(BookmarkFolder)

    var id: UUID {
        switch self {
        case .bookmark(let b): return b.id
        case .folder(let f):   return f.id
        }
    }
}

// MARK: - Persistence

private struct BookmarkPayloadV2: Codable {
    var version: Int = 2
    var bookmarks: [Bookmark]
    var folders: [BookmarkFolder]
    /// Maps `parentID?.uuidString ?? rootKey` → ordered child IDs.
    /// Stored with String keys so the JSON is a normal object.
    var childOrder: [String: [UUID]]
    var barFolderID: UUID
}

private struct BookmarkPayloadV1: Codable {
    var bookmarks: [Bookmark]
    var barOrder: [UUID]
}

// MARK: - Store

@MainActor
@Observable
final class BookmarkStore {

    /// All bookmarks. Order within siblings is governed by `childOrder`.
    private(set) var bookmarks: [Bookmark] = []

    /// All folders. Order within siblings is governed by `childOrder`.
    private(set) var folders: [BookmarkFolder] = []

    /// The folder whose direct children make up the bookmarks bar.
    /// Always non-nil after init (we ensure a default exists).
    private(set) var barFolderID: UUID

    private var childOrder: [String: [UUID]] = [:]

    private static let rootKey = "ROOT"
    private let fileURL = PersistentStore.url(for: "bookmarks.json")

    // MARK: - Undo

    private struct Snapshot {
        let bookmarks: [Bookmark]
        let folders: [BookmarkFolder]
        let childOrder: [String: [UUID]]
        let barFolderID: UUID
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private static let undoLimit = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func captureUndo() {
        let snap = Snapshot(
            bookmarks: bookmarks,
            folders: folders,
            childOrder: childOrder,
            barFolderID: barFolderID
        )
        undoStack.append(snap)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
    }

    private func restore(_ snap: Snapshot) {
        bookmarks = snap.bookmarks
        folders = snap.folders
        childOrder = snap.childOrder
        barFolderID = snap.barFolderID
    }

    func undo() {
        guard let snap = undoStack.popLast() else { return }
        let current = Snapshot(
            bookmarks: bookmarks, folders: folders,
            childOrder: childOrder, barFolderID: barFolderID
        )
        redoStack.append(current)
        restore(snap)
        persist()
    }

    func redo() {
        guard let snap = redoStack.popLast() else { return }
        let current = Snapshot(
            bookmarks: bookmarks, folders: folders,
            childOrder: childOrder, barFolderID: barFolderID
        )
        undoStack.append(current)
        restore(snap)
        persist()
    }

    // MARK: - Init

    init() {
        // Tentative bar id — overwritten by load paths below.
        self.barFolderID = UUID()
        load()
        // After load, guarantee a bar folder exists.
        if folders.first(where: { $0.id == barFolderID }) == nil {
            let bar = BookmarkFolder(name: "Favorites")
            folders.append(bar)
            childOrder[Self.rootKey, default: []].append(bar.id)
            barFolderID = bar.id
            persist()
        }
    }

    private func load() {
        if let v2: BookmarkPayloadV2 = PersistentStore.load(BookmarkPayloadV2.self, from: fileURL),
           v2.version == 2 {
            self.bookmarks = v2.bookmarks
            self.folders = v2.folders
            self.childOrder = v2.childOrder
            self.barFolderID = v2.barFolderID
            return
        }
        if let v1: BookmarkPayloadV1 = PersistentStore.load(BookmarkPayloadV1.self, from: fileURL) {
            migrate(legacy: v1)
            return
        }
        // Empty: leave defaults; init() will seed a Favorites folder.
    }

    /// v1 → v2: keep all bookmarks at root, lift `barOrder` into a
    /// fresh "Favorites" folder so previously-pinned items stay on
    /// the bar.
    private func migrate(legacy: BookmarkPayloadV1) {
        self.bookmarks = legacy.bookmarks
        let bar = BookmarkFolder(name: "Favorites")
        self.folders = [bar]
        self.barFolderID = bar.id

        let barSet = Set(legacy.barOrder)
        var rootOrder: [UUID] = []
        var barChildren: [UUID] = legacy.barOrder

        // Reparent legacy bar items into the new folder; everything
        // else stays at root.
        for i in self.bookmarks.indices {
            if barSet.contains(self.bookmarks[i].id) {
                self.bookmarks[i].parentID = bar.id
            } else {
                rootOrder.append(self.bookmarks[i].id)
            }
        }
        rootOrder.append(bar.id)
        // De-dupe defensively.
        barChildren = Array(NSOrderedSet(array: barChildren)) as? [UUID] ?? barChildren

        self.childOrder = [
            Self.rootKey:        rootOrder,
            bar.id.uuidString:   barChildren
        ]
        persist()
    }

    // MARK: - Lookup

    func isBookmarked(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// Direct children of `parent` (nil = root) in order.
    func children(of parent: UUID?) -> [BookmarkNode] {
        let key = parent?.uuidString ?? Self.rootKey
        let bookmarksByID = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
        let foldersByID   = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        return (childOrder[key] ?? []).compactMap { id in
            if let bm = bookmarksByID[id] { return .bookmark(bm) }
            if let f  = foldersByID[id]   { return .folder(f) }
            return nil
        }
    }

    /// Children of the bar folder.
    var barChildren: [BookmarkNode] { children(of: barFolderID) }

    func folder(id: UUID) -> BookmarkFolder? {
        folders.first { $0.id == id }
    }

    // MARK: - Mutations

    /// Create a new folder under `parentID` (nil = root). Returns its id.
    @discardableResult
    func createFolder(name: String, parentID: UUID? = nil) -> UUID {
        captureUndo()
        let folder = BookmarkFolder(name: name, parentID: parentID)
        folders.append(folder)
        appendChild(id: folder.id, under: parentID)
        persist()
        return folder.id
    }

    /// Add a new bookmark. Returns the existing id if the URL is
    /// already known (without changing its parent), otherwise the id
    /// of the freshly-created entry.
    @discardableResult
    func add(title: String, url: String, parentID: UUID? = nil) -> UUID? {
        guard !url.isEmpty else { return nil }
        if let existing = bookmarks.first(where: { $0.url == url }) {
            return existing.id
        }
        captureUndo()
        let display = title.isEmpty ? url : title
        let bookmark = Bookmark(title: display, url: url, parentID: parentID)
        bookmarks.append(bookmark)
        appendChild(id: bookmark.id, under: parentID)
        persist()
        return bookmark.id
    }

    /// Remove a bookmark or folder. Folders cascade-remove their
    /// descendants so the store can never end up with orphaned IDs.
    func remove(id: UUID) {
        captureUndo()
        if folders.contains(where: { $0.id == id }) {
            removeFolderCascading(id: id)
        } else {
            bookmarks.removeAll { $0.id == id }
            for k in childOrder.keys {
                childOrder[k]?.removeAll { $0 == id }
            }
        }
        persist()
    }

    /// Rename a bookmark. No-op for folders here; use `renameFolder`.
    func rename(id: Bookmark.ID, title: String) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        captureUndo()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[idx].title = trimmed.isEmpty ? bookmarks[idx].url : trimmed
        persist()
    }

    func renameFolder(id: UUID, name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        captureUndo()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[idx].name = trimmed.isEmpty ? "Folder" : trimmed
        persist()
    }

    /// Move a node to a new parent (nil = root). Inserts at `index` if
    /// given, else appends.
    func move(id: UUID, to newParent: UUID?, index: Int? = nil) {
        // Don't move a folder into itself or a descendant.
        if folders.contains(where: { $0.id == id }),
           let newParent, isDescendant(of: id, candidate: newParent) {
            return
        }
        captureUndo()
        // Detach
        for k in childOrder.keys { childOrder[k]?.removeAll { $0 == id } }
        if let bIdx = bookmarks.firstIndex(where: { $0.id == id }) {
            bookmarks[bIdx].parentID = newParent
        } else if let fIdx = folders.firstIndex(where: { $0.id == id }) {
            folders[fIdx].parentID = newParent
        } else {
            return
        }
        // Reattach
        let key = newParent?.uuidString ?? Self.rootKey
        var list = childOrder[key] ?? []
        let target = index.map { max(0, min($0, list.count)) } ?? list.count
        list.insert(id, at: target)
        childOrder[key] = list
        persist()
    }

    /// Wipe everything. Used by the "Clear All" button before a fresh
    /// import. Re-seeds an empty Favorites folder so the bar still has
    /// a home.
    func clearAll() {
        captureUndo()
        bookmarks.removeAll()
        folders.removeAll()
        childOrder.removeAll()
        let bar = BookmarkFolder(name: "Favorites")
        folders.append(bar)
        barFolderID = bar.id
        childOrder[Self.rootKey] = [bar.id]
        persist()
    }

    func removeAll(matching url: String) {
        let ids = bookmarks.filter { $0.url == url }.map(\.id)
        guard !ids.isEmpty else { return }
        captureUndo()
        bookmarks.removeAll { $0.url == url }
        for k in childOrder.keys {
            childOrder[k]?.removeAll { ids.contains($0) }
        }
        persist()
    }

    /// Convenience for the URL-bar star toggle.
    func toggle(title: String, url: String) {
        if isBookmarked(url: url) {
            removeAll(matching: url)
        } else {
            add(title: title, url: url, parentID: barFolderID)
        }
    }

    // MARK: - Bar

    /// Reorder a child of the bar folder.
    func moveInBar(id: Bookmark.ID, to targetIndex: Int) {
        let key = barFolderID.uuidString
        guard var list = childOrder[key],
              let from = list.firstIndex(of: id) else { return }
        var clamped = max(0, min(targetIndex, list.count - 1))
        if from == clamped { return }
        captureUndo()
        let item = list.remove(at: from)
        if clamped > from { clamped -= 1 }
        clamped = max(0, min(clamped, list.count))
        list.insert(item, at: clamped)
        childOrder[key] = list
        persist()
    }

    /// True when the bookmark is a direct child of the bar folder.
    func isInBar(id: Bookmark.ID) -> Bool {
        bookmarks.first(where: { $0.id == id })?.parentID == barFolderID
    }

    /// Pin/unpin a bookmark by reparenting it. Pinning moves it under
    /// the bar folder; unpinning moves it back to the root.
    func setInBar(id: Bookmark.ID, _ inBar: Bool) {
        guard bookmarks.contains(where: { $0.id == id }) else { return }
        move(id: id, to: inBar ? barFolderID : nil)
    }

    /// Adopt an imported folder as the bar folder. Replaces the
    /// previous (typically empty) Favorites placeholder.
    func setBarFolder(id: UUID) {
        guard folders.contains(where: { $0.id == id }) else { return }
        captureUndo()
        // If the previous bar folder is empty and unused, reap it.
        let previous = barFolderID
        barFolderID = id
        if previous != id,
           folders.first(where: { $0.id == previous })?.name == "Favorites",
           (childOrder[previous.uuidString] ?? []).isEmpty {
            removeFolderCascading(id: previous)
        }
        persist()
    }

    // MARK: - Internals

    private func appendChild(id: UUID, under parent: UUID?) {
        let key = parent?.uuidString ?? Self.rootKey
        childOrder[key, default: []].append(id)
    }

    private func removeFolderCascading(id: UUID) {
        // Recursively collect descendants
        var stack: [UUID] = [id]
        var dropFolders = Set<UUID>()
        var dropBookmarks = Set<UUID>()
        while let next = stack.popLast() {
            dropFolders.insert(next)
            let key = next.uuidString
            for childID in (childOrder[key] ?? []) {
                if folders.contains(where: { $0.id == childID }) {
                    stack.append(childID)
                } else {
                    dropBookmarks.insert(childID)
                }
            }
            childOrder[key] = nil
        }
        folders.removeAll { dropFolders.contains($0.id) }
        bookmarks.removeAll { dropBookmarks.contains($0.id) }
        for k in childOrder.keys {
            childOrder[k]?.removeAll { dropFolders.contains($0) || dropBookmarks.contains($0) }
        }
    }

    private func isDescendant(of folderID: UUID, candidate: UUID) -> Bool {
        var current: UUID? = candidate
        var seen = Set<UUID>()
        while let id = current {
            if id == folderID { return true }
            if !seen.insert(id).inserted { return false }
            current = folders.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    private func persist() {
        let payload = BookmarkPayloadV2(
            version: 2,
            bookmarks: bookmarks,
            folders: folders,
            childOrder: childOrder,
            barFolderID: barFolderID
        )
        PersistentStore.save(payload, to: fileURL)
    }
}

// MARK: - Compatibility shims

extension BookmarkStore {
    /// Bookmarks at the root of the bar folder, in order. Kept for
    /// callers that only need the flat list (URL-suggestion ranking,
    /// settings stats).
    var barBookmarks: [Bookmark] {
        barChildren.compactMap { node in
            if case .bookmark(let b) = node { return b } else { return nil }
        }
    }
}
