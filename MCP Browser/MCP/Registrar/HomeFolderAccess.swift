//
//  HomeFolderAccess.swift
//  MCP Browser
//
//  Sandboxed builds can't write to `~/Library/...`, `~/.cursor/...`,
//  etc. without user consent. We ask for the home folder via
//  NSOpenPanel once, persist a security-scoped bookmark, then reuse it
//  for every config file we touch. The unsandboxed build never calls
//  this — see `SandboxStatus`.
//

import AppKit
import Foundation

@MainActor
enum HomeFolderAccess {
    private static let bookmarkURL = PersistentStore.url(for: "home-folder-bookmark.json")

    private struct Payload: Codable { let data: Data }

    enum AccessError: LocalizedError {
        case userCancelled
        case wrongFolder(URL)

        var errorDescription: String? {
            switch self {
            case .userCancelled:    return nil
            case .wrongFolder(let url):
                return "Please choose your home folder, not \(url.lastPathComponent)."
            }
        }
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        if case AccessError.userCancelled = error { return true }
        return false
    }

    /// Returns a usable home URL if we already have a saved bookmark.
    static func savedHomeURL() throws -> URL? {
        guard let data = try? Data(contentsOf: bookmarkURL) else { return nil }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: payload.data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale { try save(url: url) }
        return url
    }

    static func requestHomeFolderAccess(completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Allow Access"
        panel.message = "Choose your home folder so MCP Browser can install MCP server entries in your client config files."
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(.failure(AccessError.userCancelled))
                return
            }
            do {
                try validate(url)
                try save(url: url)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    static func withAccess<T>(_ url: URL, body: () throws -> T) throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private static func save(url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let payload = Payload(data: data)
        let encoded = try JSONEncoder().encode(payload)
        try encoded.write(to: bookmarkURL, options: .atomic)
    }

    private static func validate(_ url: URL) throws {
        let selected = url.resolvingSymlinksInPath().standardizedFileURL
        let actualHome = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().standardizedFileURL
        guard selected == actualHome else {
            throw AccessError.wrongFolder(url)
        }
    }
}
