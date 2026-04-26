//
//  NavigationTools.swift
//  MCP Browser
//

import Foundation

enum NavigateTool: MCPTool {
    struct Args: Decodable { let url: String }
    static let descriptor = ToolDescriptor(
        name: "navigate",
        description: "Load a URL (or a search query) in the browser.",
        inputSchema: [
            "type": "object",
            "properties": ["url": ["type": "string", "description": "Full URL, bare domain, or search query."]],
            "required": ["url"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.url.isEmpty else {
            throw RPCError(code: -32602, message: "missing `url`")
        }
        // Fall back to spawning a tab if the focused window has none — a
        // fresh launch with a window but no tab shouldn't refuse this call.
        if let tab = host.activeBrowser {
            let loaded = tab.navigate(to: args.url)
            return .text("loading \(loaded?.absoluteString ?? args.url)")
        }
        let window = try host.requireActiveTabs()
        let tab = window.newTab(url: args.url)
        return .text("loading \(tab.currentURL?.absoluteString ?? args.url)")
    }
}

enum BackTool: MCPTool {
    static let descriptor = ToolDescriptor(name: "back", description: "Go back one entry in the browser's history.")
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        try host.requireActiveBrowser().goBack()
        return .text("ok")
    }
}

enum ForwardTool: MCPTool {
    static let descriptor = ToolDescriptor(name: "forward", description: "Go forward one entry in the browser's history.")
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        try host.requireActiveBrowser().goForward()
        return .text("ok")
    }
}

enum ReloadTool: MCPTool {
    static let descriptor = ToolDescriptor(name: "reload", description: "Reload the current page.")
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        try host.requireActiveBrowser().reload()
        return .text("ok")
    }
}

enum CurrentURLTool: MCPTool {
    static let descriptor = ToolDescriptor(name: "current_url", description: "Return the URL currently displayed.")
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .text(try host.requireActiveBrowser().currentURL?.absoluteString ?? "")
    }
}

enum CurrentTitleTool: MCPTool {
    static let descriptor = ToolDescriptor(name: "current_title", description: "Return the title of the current page.")
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .text(try host.requireActiveBrowser().pageTitle)
    }
}
