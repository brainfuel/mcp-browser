//
//  MCPClient.swift
//  MCP Browser
//
//  Shared types describing an MCP-aware client (Claude Desktop, Cursor,
//  Claude Code, Codex CLI, …) and the local server we want to register
//  with it. Designed to be portable: the same types power MCP Browser
//  (HTTP transport, sandboxed) and Publisher (stdio binary, unsandboxed).
//

import Foundation

/// How a client should reach the server. Stdio launches a local binary;
/// http points the client at a loopback URL the host app already serves.
enum MCPTransport: Sendable, Hashable {
    case stdio(binary: URL, args: [String])
    case http(url: String, headers: [String: String] = [:])
}

/// What we register: a name (the key under `mcpServers`) and how to reach it.
struct MCPServerSpec: Sendable, Hashable {
    let name: String
    let transport: MCPTransport
}

/// One MCP-aware client. Path is absolute; format selects how we patch.
struct MCPClient: Identifiable, Sendable, Hashable {
    enum Format: Sendable, Hashable { case json, toml }

    let id: String
    let displayName: String
    let configPath: URL
    let format: Format
}

/// The four clients we know about. Same list works for any host app —
/// it's just a registry of where each tool keeps its MCP config.
enum MCPClientCatalog {
    static func known() -> [MCPClient] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            MCPClient(
                id: "claude-desktop",
                displayName: "Claude Desktop",
                configPath: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                format: .json
            ),
            MCPClient(
                id: "cursor",
                displayName: "Cursor",
                configPath: home.appendingPathComponent(".cursor/mcp.json"),
                format: .json
            ),
            MCPClient(
                id: "claude-code",
                displayName: "Claude Code (user scope)",
                configPath: home.appendingPathComponent(".claude.json"),
                format: .json
            ),
            MCPClient(
                id: "codex",
                displayName: "Codex CLI",
                configPath: home.appendingPathComponent(".codex/config.toml"),
                format: .toml
            ),
        ]
    }
}
