//
//  CodexInstaller.swift
//  MCP Browser
//
//  Installs a home-local Codex plugin for MCP Browser. Because the
//  app is sandboxed, we ask the user to grant access to their home
//  folder once, persist a security-scoped bookmark, and then use that
//  permission to update ~/plugins plus ~/.agents/plugins/marketplace.json.
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CodexInstaller {
    var isInstalling = false
    var lastResult: String?
    var errorMessage: String?

    private let fileManager = FileManager.default
    private let bookmarkFileURL = PersistentStore.url(for: "codex-home-bookmark.json")

    private struct BookmarkPayload: Codable {
        let data: Data
    }

    private struct InstallPaths {
        let pluginRoot: URL
        let pluginManifest: URL
        let mcpConfig: URL
        let marketplace: URL
    }

    enum InstallError: LocalizedError {
        case chooseHomeFolder
        case invalidHomeFolder(URL)
        case invalidMarketplace
        case invalidMarketplacePlugins

        var errorDescription: String? {
            switch self {
            case .chooseHomeFolder:
                return "Choose your home folder to let MCP Browser install the Codex plugin."
            case .invalidHomeFolder(let url):
                return "Please choose your home folder, not \(url.lastPathComponent)."
            case .invalidMarketplace:
                return "The existing Codex marketplace file is not a JSON object."
            case .invalidMarketplacePlugins:
                return "The existing Codex marketplace file has an invalid plugins array."
            }
        }
    }

    var savedHomePath: String? {
        guard let url = try? resolveSavedHomeURL() else { return nil }
        return url.path
    }

    var pluginRootURL: URL? {
        guard let paths = try? installPaths() else { return nil }
        return paths.pluginRoot
    }

    var marketplaceURL: URL? {
        guard let paths = try? installPaths() else { return nil }
        return paths.marketplace
    }

    var hasSavedHomeFolder: Bool {
        savedHomePath != nil
    }

    var isInstalled: Bool {
        guard let paths = try? installPaths() else { return false }
        return fileManager.fileExists(atPath: paths.pluginManifest.path)
            && fileManager.fileExists(atPath: paths.mcpConfig.path)
            && fileManager.fileExists(atPath: paths.marketplace.path)
    }

    func install(endpoint: String) {
        guard !isInstalling else { return }
        errorMessage = nil
        lastResult = nil

        if let homeURL = try? resolveSavedHomeURL() {
            performInstall(homeURL: homeURL, endpoint: endpoint)
            return
        }

        requestHomeFolderAccess(endpoint: endpoint)
    }

    func chooseHomeFolder() {
        requestHomeFolderAccess(endpoint: nil)
    }

    func revealPluginInFinder() {
        guard let url = pluginRootURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func requestHomeFolderAccess(endpoint: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = fileManager.homeDirectoryForCurrentUser
        panel.prompt = "Allow Access"
        panel.message = "Choose your home folder so MCP Browser can install or update the Codex plugin in ~/plugins and ~/.agents."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                if response == .cancel { return }
                self?.errorMessage = InstallError.chooseHomeFolder.localizedDescription
                return
            }

            do {
                try self.validateHomeFolder(url)
                try self.saveHomeBookmark(for: url)
                self.lastResult = "Granted access to \(self.tildePath(for: url))."
                self.errorMessage = nil
                if let endpoint {
                    self.performInstall(homeURL: url, endpoint: endpoint)
                }
            } catch {
                self.lastResult = nil
                self.errorMessage = self.describe(error)
            }
        }
    }

    private func performInstall(homeURL: URL, endpoint: String) {
        isInstalling = true
        defer { isInstalling = false }

        do {
            let paths = paths(for: homeURL)
            try withSecurityScopedAccess(to: homeURL) {
                try fileManager.createDirectory(at: paths.pluginManifest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.pluginRoot, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.marketplace.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

                try writeJSON(pluginManifest(), to: paths.pluginManifest)
                try writeJSON(mcpConfig(endpoint: endpoint), to: paths.mcpConfig)
                try updateMarketplace(at: paths.marketplace)
            }

            lastResult = "Installed Codex integration at ~/plugins/mcp-browser and updated ~/.agents/plugins/marketplace.json."
            errorMessage = nil
        } catch {
            lastResult = nil
            errorMessage = describe(error)
        }
    }

    private func resolveSavedHomeURL() throws -> URL? {
        guard let data = try? Data(contentsOf: bookmarkFileURL) else { return nil }
        let payload = try JSONDecoder().decode(BookmarkPayload.self, from: data)
        var stale = false
        let url = try URL(
            resolvingBookmarkData: payload.data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            try saveHomeBookmark(for: url)
        }
        return url
    }

    private func saveHomeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        let payload = BookmarkPayload(data: data)
        let encoded = try JSONEncoder().encode(payload)
        try encoded.write(to: bookmarkFileURL, options: .atomic)
    }

    private func installPaths() throws -> InstallPaths {
        guard let homeURL = try resolveSavedHomeURL() else {
            throw InstallError.chooseHomeFolder
        }
        return paths(for: homeURL)
    }

    private func paths(for homeURL: URL) -> InstallPaths {
        let pluginRoot = homeURL.appendingPathComponent("plugins/mcp-browser", isDirectory: true)
        return InstallPaths(
            pluginRoot: pluginRoot,
            pluginManifest: pluginRoot.appendingPathComponent(".codex-plugin/plugin.json"),
            mcpConfig: pluginRoot.appendingPathComponent(".mcp.json"),
            marketplace: homeURL.appendingPathComponent(".agents/plugins/marketplace.json")
        )
    }

    private func validateHomeFolder(_ url: URL) throws {
        let selected = url.resolvingSymlinksInPath().standardizedFileURL
        let actualHome = fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        guard selected == actualHome else {
            throw InstallError.invalidHomeFolder(url)
        }
    }

    private func withSecurityScopedAccess<T>(to url: URL, body: () throws -> T) throws -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        return try body()
    }

    private func updateMarketplace(at url: URL) throws {
        var payload: [String: Any]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError.invalidMarketplace
            }
            payload = root
        } else {
            payload = [
                "name": "local",
                "interface": [
                    "displayName": "Local Plugins"
                ],
                "plugins": [[String: Any]]()
            ]
        }

        let rawPlugins = payload["plugins"] ?? []
        guard let pluginItems = rawPlugins as? [Any] else {
            throw InstallError.invalidMarketplacePlugins
        }
        var plugins: [[String: Any]] = []
        for item in pluginItems {
            guard let dict = item as? [String: Any] else {
                throw InstallError.invalidMarketplacePlugins
            }
            plugins.append(dict)
        }

        let entry: [String: Any] = [
            "name": "mcp-browser",
            "source": [
                "source": "local",
                "path": "./plugins/mcp-browser"
            ],
            "policy": [
                "installation": "AVAILABLE",
                "authentication": "ON_INSTALL"
            ],
            "category": "Productivity"
        ]

        if let index = plugins.firstIndex(where: { $0["name"] as? String == "mcp-browser" }) {
            plugins[index] = entry
        } else {
            plugins.append(entry)
        }

        if payload["name"] == nil {
            payload["name"] = "local"
        }
        if payload["interface"] == nil {
            payload["interface"] = ["displayName": "Local Plugins"]
        }
        payload["plugins"] = plugins
        try writeJSON(payload, to: url)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func pluginManifest() -> [String: Any] {
        [
            "name": "mcp-browser",
            "version": "0.1.0",
            "description": "Use MCP Browser's local HTTP MCP server from Codex to control and inspect web pages in a persistent browser window.",
            "author": [
                "name": "Ben Milford",
                "email": "brainfuel@icloud.com"
            ],
            "license": "Proprietary",
            "keywords": [
                "browser",
                "mcp",
                "web-automation",
                "inspection"
            ],
            "mcpServers": "./.mcp.json",
            "interface": [
                "displayName": "MCP Browser",
                "shortDescription": "Control MCP Browser from Codex",
                "longDescription": "Connects Codex to the local MCP Browser app over HTTP so it can navigate pages, inspect content, interact with forms, manage tabs, capture screenshots, and work with downloads in a persistent browser session. MCP Browser must be running locally for the connection to succeed.",
                "developerName": "Ben Milford",
                "category": "Productivity",
                "capabilities": [
                    "Interactive",
                    "Read",
                    "Write"
                ],
                "defaultPrompt": [
                    "Open a page in MCP Browser and summarize it",
                    "Inspect the current page and list the important links",
                    "Drive a login flow in MCP Browser step by step"
                ],
                "brandColor": "#2563EB",
                "screenshots": [String]()
            ]
        ]
    }

    private func mcpConfig(endpoint: String) -> [String: Any] {
        [
            "mcpServers": [
                "mcp-browser": [
                    "type": "http",
                    "url": endpoint,
                    "note": "Connects to the local MCP Browser app over HTTP. Start MCP Browser before using this server in Codex."
                ]
            ]
        ]
    }

    private func tildePath(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
