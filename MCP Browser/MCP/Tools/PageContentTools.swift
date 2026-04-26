//
//  PageContentTools.swift
//  MCP Browser
//

import Foundation

enum ReadTextTool: MCPTool {
    struct Args: Decodable { let mode: String? }
    static let descriptor = ToolDescriptor(
        name: "read_text",
        description: "Return text content of the current page. `mode: \"visible\"` (default) reads innerText (visible only, layout-aware spacing). `mode: \"all\"` does a deep DOM walk including shadow roots, same-origin iframes, image alt, aria-label, and form labels — captures considerably more on virtualized or component-heavy pages.",
        inputSchema: [
            "type": "object",
            "properties": [
                "mode": [
                    "type": "string",
                    "enum": ["visible", "all"],
                    "description": "Defaults to \"visible\"."
                ]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let mode = BrowserTab.ReadTextMode(rawValue: args.mode ?? "visible") ?? .visible
        return .text(try await host.requireActiveBrowser().readText(mode: mode))
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
    struct Args: Decodable { let filename: String?; let selector: String? }
    static let descriptor = ToolDescriptor(
        name: "screenshot",
        description: "Take a PNG snapshot. Pass `selector` to crop to a specific element (scrolled into view first); omit it for the full viewport. Without `filename`, returns base64-encoded image content; with `filename`, saves to ~/Downloads and returns the file path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string", "description": "Optional CSS selector. When set, crops the snapshot to that element's bounding box."],
                "filename": ["type": "string", "description": "Optional filename to save the PNG to ~/Downloads (.png added if missing). When set, the tool returns the saved file path instead of inline image content."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let tab = try host.requireActiveBrowser()
        if let selector = args.selector, !selector.isEmpty {
            if let filename = args.filename {
                let dest = try await tab.screenshotElementPNG(selector: selector, filename: filename)
                return .text(dest.path)
            }
            let png = try await tab.screenshotElementPNG(selector: selector)
            return .image(png)
        }
        if let filename = args.filename {
            let dest = try await tab.screenshotPNG(filename: filename)
            return .text(dest.path)
        }
        let png = try await tab.screenshotPNG()
        return .image(png)
    }
}

enum PageMetadataTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "page_metadata",
        description: "Return structured page-identifying metadata: title, URL, language, charset, description, canonical link, viewport meta, theme color, OpenGraph + Twitter Card tags, generic <meta name=...> entries, favicons, manifest, and RSS feeds."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().pageMetadata() ?? NSNull())
    }
}

enum EmulateTool: MCPTool {
    struct Args: Decodable {
        let user_agent: String?
        let width: Int?
        let height: Int?
        let zoom: Double?
    }
    static let descriptor = ToolDescriptor(
        name: "emulate",
        description: "Set viewport / device emulation. `user_agent` overrides the User-Agent header (empty string clears it). `width`+`height` resize the host window so the page sees that viewport (must be paired). `zoom` is page magnification (1.0 = 100%). All fields are optional and applied independently.",
        inputSchema: [
            "type": "object",
            "properties": [
                "user_agent": ["type": "string", "description": "Custom User-Agent. Pass empty string to clear."],
                "width":  ["type": "integer", "description": "Viewport width in points. Pair with `height`."],
                "height": ["type": "integer", "description": "Viewport height in points. Pair with `width`."],
                "zoom":   ["type": "number",  "description": "Page magnification. 1.0 = 100%."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        if (args.width == nil) != (args.height == nil) {
            throw RPCError(code: -32602, message: "`width` and `height` must be set together")
        }
        let state = try await host.requireActiveBrowser().emulate(
            userAgent: args.user_agent, width: args.width, height: args.height, zoom: args.zoom
        )
        var out: [String: Any] = [:]
        if let ua = state.userAgent { out["user_agent"] = ua }
        if let w = state.width      { out["width"]  = w }
        if let h = state.height     { out["height"] = h }
        if let z = state.zoom       { out["zoom"]   = z }
        return .json(out)
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
