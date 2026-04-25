//
//  DOMTools.swift
//  MCP Browser
//

import Foundation

enum ClickTool: MCPTool {
    struct Args: Decodable { let selector: String }
    static let descriptor = ToolDescriptor(
        name: "click",
        description: "Click an element matched by a CSS selector.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string", "description": "CSS selector for the target element."]],
            "required": ["selector"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let hit = try await host.requireActiveBrowser().click(selector: args.selector)
        return .text(hit ? "clicked" : "not found", isError: !hit)
    }
}

enum FillTool: MCPTool {
    struct Args: Decodable { let selector: String; let value: String }
    static let descriptor = ToolDescriptor(
        name: "fill",
        description: "Set the value of an input, textarea, or contenteditable matched by a CSS selector. Dispatches input/change events.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string"],
                "value":    ["type": "string"]
            ],
            "required": ["selector", "value"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let hit = try await host.requireActiveBrowser().fill(selector: args.selector, value: args.value)
        return .text(hit ? "filled" : "not found", isError: !hit)
    }
}

enum SubmitTool: MCPTool {
    struct Args: Decodable { let selector: String? }
    static let descriptor = ToolDescriptor(
        name: "submit",
        description: "Submit a form. If `selector` is given it should match a form or an element inside one; otherwise submits the form containing document.activeElement.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string", "description": "Optional. Form or descendant element selector."]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let ok = try await host.requireActiveBrowser().submit(selector: args.selector)
        return .text(ok ? "submitted" : "no form", isError: !ok)
    }
}

enum WaitForTool: MCPTool {
    struct Args: Decodable {
        let selector: String?
        let url: String?
        let idle: Bool?
        let timeout_ms: Int?
    }
    static let descriptor = ToolDescriptor(
        name: "wait_for",
        description: "Wait for a condition to hold. Provide exactly one of `selector`, `url` (substring match), or set `idle` true to wait until the page finishes loading.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector":   ["type": "string"],
                "url":        ["type": "string"],
                "idle":       ["type": "boolean"],
                "timeout_ms": ["type": "integer", "description": "Default 10000."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let timeout = args.timeout_ms ?? 10_000
        let browser = try host.requireActiveBrowser()
        let ok: Bool
        if let sel = args.selector, !sel.isEmpty {
            ok = try await browser.waitForSelector(sel, timeoutMs: timeout)
        } else if let url = args.url, !url.isEmpty {
            ok = try await browser.waitForURL(url, timeoutMs: timeout)
        } else if args.idle == true {
            ok = try await browser.waitForIdle(timeoutMs: timeout)
        } else {
            throw RPCError(code: -32602, message: "wait_for requires one of `selector`, `url`, or `idle:true`")
        }
        return .text(ok ? "matched" : "timeout", isError: !ok)
    }
}

enum ScrollTool: MCPTool {
    struct Args: Decodable {
        let selector: String?
        let x: Double?; let y: Double?
        let dx: Double?; let dy: Double?
    }
    static let descriptor = ToolDescriptor(
        name: "scroll",
        description: "Scroll the page. Pass `selector` to scroll an element into view, `x`+`y` for absolute position, or `dx`+`dy` for a delta.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string"],
                "x":  ["type": "number"], "y":  ["type": "number"],
                "dx": ["type": "number"], "dy": ["type": "number"]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let ok = try await host.requireActiveBrowser().scroll(
            selector: args.selector,
            x: args.x, y: args.y, dx: args.dx, dy: args.dy
        )
        return .text(ok ? "ok" : "nothing to do", isError: !ok)
    }
}
