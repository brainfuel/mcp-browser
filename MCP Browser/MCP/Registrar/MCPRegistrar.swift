//
//  MCPRegistrar.swift
//  MCP Browser
//
//  Orchestrates install / uninstall / status across a list of clients
//  for a given server spec. Two impls so the same source tree works
//  for both an unsandboxed direct-download / open-source build
//  (`DirectFSRegistrar`) and a sandboxed Mac App Store build
//  (`SecurityScopedRegistrar`). `MCPRegistrarFactory.makeDefault()`
//  picks the right one at runtime by reading the process's own
//  `com.apple.security.app-sandbox` entitlement.
//

import Foundation
import Observation

protocol MCPRegistrar: AnyObject {
    /// `true` if the client's config currently references our server.
    func isInstalled(client: MCPClient, spec: MCPServerSpec) -> Bool

    /// Patch the client's config to add (or update) our server entry.
    /// Returns the file the user can show in Finder.
    @discardableResult
    func install(client: MCPClient, spec: MCPServerSpec) async throws -> URL

    /// Remove our server entry from the client's config. No-op if absent.
    func uninstall(client: MCPClient, spec: MCPServerSpec) async throws
}

// MARK: - Direct file system (unsandboxed hosts)

/// Used by Publisher. Reads and writes config files directly.
final class DirectFSRegistrar: MCPRegistrar {
    func isInstalled(client: MCPClient, spec: MCPServerSpec) -> Bool {
        let data = try? Data(contentsOf: client.configPath)
        return MCPConfigPatcher.isInstalled(in: data, format: client.format, name: spec.name)
    }

    @discardableResult
    func install(client: MCPClient, spec: MCPServerSpec) async throws -> URL {
        try ensureParent(of: client.configPath)
        let existing = try? Data(contentsOf: client.configPath)
        try writePatched(existing: existing, to: client.configPath, client: client, spec: spec)
        return client.configPath
    }

    func uninstall(client: MCPClient, spec: MCPServerSpec) async throws {
        guard let existing = try? Data(contentsOf: client.configPath) else { return }
        try writeUnpatched(existing: existing, to: client.configPath, client: client, spec: spec)
    }

    private func ensureParent(of url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    fileprivate func writePatched(existing: Data?, to url: URL, client: MCPClient, spec: MCPServerSpec) throws {
        switch client.format {
        case .json:
            let out = try MCPConfigPatcher.upsertJSON(existing: existing, spec: spec)
            try out.write(to: url, options: .atomic)
        case .toml:
            let text = existing.flatMap { String(data: $0, encoding: .utf8) }
            let updated = MCPConfigPatcher.upsertTOML(existing: text, spec: spec)
            try Data(updated.utf8).write(to: url, options: .atomic)
        }
    }

    fileprivate func writeUnpatched(existing: Data, to url: URL, client: MCPClient, spec: MCPServerSpec) throws {
        switch client.format {
        case .json:
            guard let out = try MCPConfigPatcher.removeJSON(existing: existing, name: spec.name) else { return }
            try out.write(to: url, options: .atomic)
        case .toml:
            let text = String(data: existing, encoding: .utf8) ?? ""
            guard let updated = MCPConfigPatcher.removeTOML(existing: text, name: spec.name) else { return }
            try Data(updated.utf8).write(to: url, options: .atomic)
        }
    }
}

// MARK: - Security scoped (App Store / sandboxed builds)

/// Routes file ops through a one-time home-folder bookmark obtained
/// via `NSOpenPanel`. Only used when the running build is sandboxed.
@MainActor
final class SecurityScopedRegistrar: MCPRegistrar {

    func isInstalled(client: MCPClient, spec: MCPServerSpec) -> Bool {
        guard let homeURL = (try? HomeFolderAccess.savedHomeURL()) ?? nil else { return false }
        let data = try? HomeFolderAccess.withAccess(homeURL) {
            try? Data(contentsOf: client.configPath)
        }
        return MCPConfigPatcher.isInstalled(in: data ?? nil, format: client.format, name: spec.name)
    }

    @discardableResult
    func install(client: MCPClient, spec: MCPServerSpec) async throws -> URL {
        let homeURL = try await acquireHomeURL()
        return try HomeFolderAccess.withAccess(homeURL) {
            try FileManager.default.createDirectory(
                at: client.configPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = try? Data(contentsOf: client.configPath)
            try DirectFSRegistrar().writePatched(
                existing: existing,
                to: client.configPath,
                client: client,
                spec: spec
            )
            return client.configPath
        }
    }

    func uninstall(client: MCPClient, spec: MCPServerSpec) async throws {
        let homeURL = try await acquireHomeURL()
        try HomeFolderAccess.withAccess(homeURL) {
            guard let existing = try? Data(contentsOf: client.configPath) else { return }
            try DirectFSRegistrar().writeUnpatched(
                existing: existing,
                to: client.configPath,
                client: client,
                spec: spec
            )
        }
    }

    private func acquireHomeURL() async throws -> URL {
        if let existing = (try? HomeFolderAccess.savedHomeURL()) ?? nil { return existing }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            HomeFolderAccess.requestHomeFolderAccess { result in
                cont.resume(with: result)
            }
        }
    }
}

// MARK: - Factory

@MainActor
enum MCPRegistrarFactory {
    /// Returns the registrar appropriate for the running build —
    /// security-scoped if sandboxed, direct-FS otherwise.
    static func makeDefault() -> any MCPRegistrar {
        SandboxStatus.isSandboxed
            ? SecurityScopedRegistrar()
            : DirectFSRegistrar()
    }
}
