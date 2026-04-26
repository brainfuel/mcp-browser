//
//  BookmarkTools.swift
//  MCP Browser
//
//  Bookmark inspection + folder open. Lets the agent enumerate the
//  user's bookmark tree and bulk-open every URL inside a named folder
//  ("open all bookmarks in folder 'Agent'").
//

import Foundation

private struct BookmarkRefs {
    /// Find a folder by case-insensitive name match. Searches the
    /// whole tree; returns nil if the name doesn't resolve unambiguously.
    /// On multiple matches, prefers a direct child of the bar folder,
    /// then the shallowest match by tree depth.
    @MainActor
    static func resolveFolder(named name: String, in store: BookmarkStore) -> BookmarkFolder? {
        let needle = name.lowercased()
        let exact = store.foldersFlat.filter { $0.name.lowercased() == needle }
        if exact.count == 1 { return exact[0] }
        if let inBar = exact.first(where: { $0.parentID == store.barFolderID }) { return inBar }
        if let firstShallow = exact.min(by: { depth(of: $0, in: store) < depth(of: $1, in: store) }) {
            return firstShallow
        }
        return nil
    }

    @MainActor
    private static func depth(of folder: BookmarkFolder, in store: BookmarkStore) -> Int {
        var d = 0
        var current: UUID? = folder.parentID
        while let id = current {
            d += 1
            current = store.foldersFlat.first(where: { $0.id == id })?.parentID
            if d > 64 { break }
        }
        return d
    }

    @MainActor
    static func nodeJSON(_ node: BookmarkNode, in store: BookmarkStore, includeChildren: Bool) -> [String: Any] {
        switch node {
        case .bookmark(let b):
            return [
                "type": "bookmark",
                "id": b.id.uuidString,
                "title": b.title,
                "url": b.url
            ]
        case .folder(let f):
            var out: [String: Any] = [
                "type": "folder",
                "id": f.id.uuidString,
                "name": f.name
            ]
            if includeChildren {
                out["children"] = store.children(of: f.id).map {
                    nodeJSON($0, in: store, includeChildren: true)
                }
            }
            return out
        }
    }
}

extension BookmarkStore {
    /// Flat snapshot of every folder. Used for tree-wide name lookup.
    fileprivate var foldersFlat: [BookmarkFolder] {
        // Mirror the private `folders` array via the public API. We
        // recursively walk from root.
        var out: [BookmarkFolder] = []
        var stack: [UUID?] = [nil]
        while let parent = stack.popLast() {
            for node in children(of: parent) {
                if case .folder(let f) = node {
                    out.append(f)
                    stack.append(f.id)
                }
            }
        }
        return out
    }

    /// Every bookmark inside `folderID`, recursively, depth-first.
    fileprivate func bookmarksRecursive(under folderID: UUID) -> [Bookmark] {
        var out: [Bookmark] = []
        var stack: [UUID] = [folderID]
        while let next = stack.popLast() {
            for node in children(of: next) {
                switch node {
                case .bookmark(let b): out.append(b)
                case .folder(let f):   stack.append(f.id)
                }
            }
        }
        return out
    }
}

enum ListBookmarksTool: MCPTool {
    struct Args: Decodable { let folder: String?; let recursive: Bool? }
    static let descriptor = ToolDescriptor(
        name: "list_bookmarks",
        description: "List bookmarks and folders. With no `folder`, returns the full tree starting from the root. With `folder` (folder name, case-insensitive), returns just that folder's children. Set `recursive: false` to limit to direct children only (default true).",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder":    ["type": "string", "description": "Optional folder name. When omitted, lists the whole tree."],
                "recursive": ["type": "boolean", "description": "Include nested folder contents. Default true."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let store = host.bookmarks
        let recursive = args.recursive ?? true
        let parent: UUID?
        if let name = args.folder, !name.isEmpty {
            guard let folder = BookmarkRefs.resolveFolder(named: name, in: store) else {
                throw RPCError(code: -32000, message: "no folder named \"\(name)\"")
            }
            parent = folder.id
        } else {
            parent = nil
        }
        let nodes = store.children(of: parent).map {
            BookmarkRefs.nodeJSON($0, in: store, includeChildren: recursive)
        }
        return .json(nodes)
    }
}

enum OpenBookmarkFolderTool: MCPTool {
    struct Args: Decodable {
        let folder: String
        let recursive: Bool?
        let limit: Int?
    }
    static let descriptor = ToolDescriptor(
        name: "open_bookmark_folder",
        description: "Open every bookmark in a folder, each in its own new tab. `folder` is the folder name (case-insensitive). `recursive` includes bookmarks in nested subfolders (default true). `limit` caps the number of tabs opened (default 50).",
        inputSchema: [
            "type": "object",
            "properties": [
                "folder":    ["type": "string"],
                "recursive": ["type": "boolean", "description": "Include nested subfolders. Default true."],
                "limit":     ["type": "integer", "description": "Max tabs to open. Default 50."]
            ],
            "required": ["folder"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.folder.isEmpty else { throw RPCError(code: -32602, message: "missing `folder`") }
        let store = host.bookmarks
        guard let folder = BookmarkRefs.resolveFolder(named: args.folder, in: store) else {
            throw RPCError(code: -32000, message: "no folder named \"\(args.folder)\"")
        }
        let recursive = args.recursive ?? true
        let limit = max(1, args.limit ?? 50)
        let bookmarks: [Bookmark] = recursive
            ? store.bookmarksRecursive(under: folder.id)
            : store.children(of: folder.id).compactMap { node in
                if case .bookmark(let b) = node { return b } else { return nil }
            }
        guard !bookmarks.isEmpty else {
            return .text("folder \"\(folder.name)\" has no bookmarks", isError: true)
        }
        let toOpen = Array(bookmarks.prefix(limit))
        let window: BrowserWindow
        if let active = host.activeTabs {
            window = active
        } else {
            throw RPCError(code: -32000, message: "no active browser window")
        }
        var opened: [[String: Any]] = []
        for b in toOpen {
            let tab = window.newTab(url: b.url)
            opened.append(["title": b.title, "url": tab.currentURL?.absoluteString ?? b.url])
        }
        let truncated = bookmarks.count > toOpen.count
        return .json([
            "folder": folder.name,
            "opened": opened,
            "total":  bookmarks.count,
            "truncated": truncated
        ])
    }
}
