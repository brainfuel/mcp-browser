//
//  PageContentTools.swift
//  MCP Browser
//

import Foundation

enum ReadTextTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "read_text",
        description: "Return the visible text content of the current page (document.body.innerText)."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .text(try await host.requireActiveBrowser().readText())
    }
}

enum EvalJSTool: MCPTool {
    struct Args: Decodable { let script: String }
    static let descriptor = ToolDescriptor(
        name: "eval_js",
        description: "Evaluate a JavaScript expression in the page's main world and return the result as a string.",
        inputSchema: [
            "type": "object",
            "properties": ["script": ["type": "string", "description": "JavaScript expression to evaluate."]],
            "required": ["script"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        .text(try await host.requireActiveBrowser().evalJS(args.script))
    }
}

enum ScreenshotTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "screenshot",
        description: "Take a PNG snapshot of the current page and return it as base64-encoded image content."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        let png = try await host.requireActiveBrowser().screenshotPNG()
        return .image(png)
    }
}

enum RenderHTMLTool: MCPTool {
    struct Args: Decodable {
        let html: String
        let baseURL: String?
    }
    static let descriptor = ToolDescriptor(
        name: "render_html",
        description: "Render a raw HTML string directly in the browser window. Use this to display agent-generated content without hosting it. Relative asset URLs are resolved against `baseURL` if provided.",
        inputSchema: [
            "type": "object",
            "properties": [
                "html":    ["type": "string", "description": "The HTML document or fragment to render."],
                "baseURL": ["type": "string", "description": "Optional base URL for resolving relative references. Defaults to about:blank."]
            ],
            "required": ["html"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let baseURL = args.baseURL.flatMap(URL.init(string:))
        try host.requireActiveBrowser().renderHTML(args.html, baseURL: baseURL)
        return .text("rendered \(args.html.count) byte(s) of HTML")
    }
}
