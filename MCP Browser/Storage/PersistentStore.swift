//
//  PersistentStore.swift
//  MCP Browser
//
//  Small JSON-on-disk helper used by BookmarkStore and HistoryStore.
//  Writes live inside the sandbox container, so nothing here needs
//  user-selected file access.
//

import Foundation

enum PersistentStore {
    /// Application Support / MCP Browser / <file>
    static func url(for filename: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("MCP Browser", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.iso8601.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.iso8601.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
