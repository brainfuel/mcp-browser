//
//  InspectionTools.swift
//  MCP Browser
//

import Foundation

enum GetElementTool: MCPTool {
    struct Args: Decodable { let selector: String }
    static let descriptor = ToolDescriptor(
        name: "get_element",
        description: "Inspect a single element: tag, text, value, attributes, and bounding rect. Returns null if not found.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string"]],
            "required": ["selector"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let any = try await host.requireActiveBrowser().getElement(selector: args.selector)
        return .json(any)
    }
}

enum ListLinksTool: MCPTool {
    struct Args: Decodable { let limit: Int? }
    static let descriptor = ToolDescriptor(
        name: "list_links",
        description: "Return all anchor links on the page as {text, href}. Cheaper than read_text for navigation.",
        inputSchema: [
            "type": "object",
            "properties": ["limit": ["type": "integer", "description": "Max links to return. Default 200."]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().listLinks(limit: args.limit ?? 200))
    }
}

enum ListFormsTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "list_forms",
        description: "Return all forms with their fields, types, values, and best-effort labels."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().listForms())
    }
}

enum AccessibilityTreeTool: MCPTool {
    struct Args: Decodable { let max_depth: Int?; let max_nodes: Int? }
    static let descriptor = ToolDescriptor(
        name: "accessibility_tree",
        description: "Return a lightweight accessibility snapshot built from the DOM (role, name, tag, children). Better than read_text for structured navigation.",
        inputSchema: [
            "type": "object",
            "properties": [
                "max_depth": ["type": "integer", "description": "Default 20."],
                "max_nodes": ["type": "integer", "description": "Default 2000."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let any = try await host.requireActiveBrowser().accessibilityTree(
            maxDepth: args.max_depth ?? 20,
            maxNodes: args.max_nodes ?? 2000
        )
        return .json(any)
    }
}

enum FindInPageTool: MCPTool {
    struct Args: Decodable {
        let query: String
        let case_sensitive: Bool?
        let limit: Int?
    }
    static let descriptor = ToolDescriptor(
        name: "find_in_page",
        description: "Find every occurrence of `query` in the page text. Returns {match, context, bounds} entries.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query":          ["type": "string"],
                "case_sensitive": ["type": "boolean"],
                "limit":          ["type": "integer", "description": "Default 200."]
            ],
            "required": ["query"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.query.isEmpty else { throw RPCError(code: -32602, message: "missing `query`") }
        let any = try await host.requireActiveBrowser().findInPage(
            query: args.query,
            caseSensitive: args.case_sensitive ?? false,
            limit: args.limit ?? 200
        )
        return .json(any)
    }
}
