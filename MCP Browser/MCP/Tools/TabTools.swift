//
//  TabTools.swift
//  MCP Browser
//

import Foundation

enum NewTabTool: MCPTool {
    struct Args: Decodable { let url: String? }
    static let descriptor = ToolDescriptor(
        name: "new_tab",
        description: "Open a new tab in the active window. Optionally navigate it to a URL.",
        inputSchema: [
            "type": "object",
            "properties": ["url": ["type": "string"]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let id = try host.requireActiveTabs().newTab(url: args.url).id.uuidString
        return .text(id)
    }
}

enum CloseTabTool: MCPTool {
    struct Args: Decodable { let id: String }
    static let descriptor = ToolDescriptor(
        name: "close_tab",
        description: "Close a tab by id. Refuses to close the last remaining tab.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "Tab id from list_tabs."]],
            "required": ["id"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard let uuid = UUID(uuidString: args.id) else {
            throw RPCError(code: -32602, message: "invalid `id`")
        }
        let ok = try host.requireActiveTabs().closeTab(id: uuid)
        return .text(ok ? "closed" : "cannot close (last tab or unknown id)", isError: !ok)
    }
}

enum SwitchTabTool: MCPTool {
    struct Args: Decodable { let id: String }
    static let descriptor = ToolDescriptor(
        name: "switch_tab",
        description: "Make a given tab the active one. Subsequent tool calls target it.",
        inputSchema: [
            "type": "object",
            "properties": ["id": ["type": "string"]],
            "required": ["id"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard let uuid = UUID(uuidString: args.id) else {
            throw RPCError(code: -32602, message: "invalid `id`")
        }
        let ok = try host.requireActiveTabs().switchTab(id: uuid)
        return .text(ok ? "switched" : "unknown id", isError: !ok)
    }
}

enum ListTabsTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "list_tabs",
        description: "List tabs in the active window as {id, url, title, active}."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        let tabs = try host.requireActiveTabs()
        let activeID = tabs.active?.id
        let payload: [[String: Any]] = tabs.tabs.map { t in
            [
                "id":     t.id.uuidString,
                "url":    t.currentURL?.absoluteString ?? "",
                "title":  t.pageTitle,
                "active": t.id == activeID
            ]
        }
        return .json(payload)
    }
}
