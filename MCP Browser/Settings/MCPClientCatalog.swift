//
//  MCPClientCatalog.swift
//  MCP Browser
//
//  Describes well-known MCP clients and how to wire the running
//  MCP Browser HTTP endpoint into each. The app is sandboxed so we
//  can't edit their config files directly — instead we hand the user
//  a ready-to-paste JSON snippet plus instructions.
//

import Foundation

struct MCPClientInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let configPathHint: String
    let instructions: String
    /// Key under which this client stores MCP servers. Used to frame
    /// the snippet so it can just be merged into an existing config.
    let entryKey: String

    /// Produces a JSON snippet the user can paste into the client's
    /// mcpServers section. The snippet includes the `"mcp-browser":`
    /// key; drop it inside the existing `"mcpServers": { ... }` object.
    func snippet(endpoint: String) -> String {
        """
        "mcp-browser": {
          "type": "http",
          "url": "\(endpoint)"
        }
        """
    }
}

enum MCPClientCatalog {
    static let all: [MCPClientInfo] = [
        MCPClientInfo(
            id: "agentic",
            name: "Agentic",
            configPathHint: "Add as a Custom Server in the Inspector.",
            instructions: "In Agentic: Tools inspector → Custom Server → Add → paste the URL.",
            entryKey: "mcpServers"
        ),
        MCPClientInfo(
            id: "claude-desktop",
            name: "Claude Desktop",
            configPathHint: "~/Library/Application Support/Claude/claude_desktop_config.json",
            instructions: "Quit Claude, open the config file above, paste the snippet inside the \"mcpServers\" object, save, and relaunch Claude.",
            entryKey: "mcpServers"
        ),
        MCPClientInfo(
            id: "cursor",
            name: "Cursor",
            configPathHint: "~/.cursor/mcp.json",
            instructions: "Open the config above and paste the snippet inside \"mcpServers\". Cursor picks it up on next launch.",
            entryKey: "mcpServers"
        ),
        MCPClientInfo(
            id: "claude-code",
            name: "Claude Code",
            configPathHint: "run `claude mcp add` in a terminal",
            instructions: "Easiest path: `claude mcp add --transport http mcp-browser <URL>`. That writes the user-scope config for you.",
            entryKey: "mcpServers"
        ),
    ]
}
