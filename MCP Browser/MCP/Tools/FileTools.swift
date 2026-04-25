//
//  FileTools.swift
//  MCP Browser
//

import Foundation

enum DownloadTool: MCPTool {
    struct Args: Decodable { let url: String; let filename: String? }
    static let descriptor = ToolDescriptor(
        name: "download",
        description: "Download a URL and save it to ~/Downloads. Returns the local file path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url":      ["type": "string"],
                "filename": ["type": "string", "description": "Optional override filename."]
            ],
            "required": ["url"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard let url = URL(string: args.url) else {
            throw RPCError(code: -32602, message: "invalid `url`")
        }
        let dest = try await host.requireActiveBrowser().download(url: url, filename: args.filename)
        return .text(dest.path)
    }
}

enum UploadFileTool: MCPTool {
    struct Args: Decodable { let selector: String; let path: String }
    static let descriptor = ToolDescriptor(
        name: "upload_file",
        description: "Upload a local file through an input[type=file] element. Set `selector` to match the input; `path` is an absolute or tilde-expanded local path. The file must be readable by the sandbox.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string"],
                "path":     ["type": "string"]
            ],
            "required": ["selector", "path"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        guard !args.path.isEmpty else { throw RPCError(code: -32602, message: "missing `path`") }
        let ok = try await host.requireActiveBrowser().uploadFile(selector: args.selector, path: args.path)
        return .text(ok ? "uploaded" : "not found", isError: !ok)
    }
}

enum PDFExportTool: MCPTool {
    struct Args: Decodable { let filename: String? }
    static let descriptor = ToolDescriptor(
        name: "pdf_export",
        description: "Export the current page to PDF and save it to ~/Downloads. Returns the file path.",
        inputSchema: [
            "type": "object",
            "properties": [
                "filename": ["type": "string", "description": "Optional override filename (.pdf added if missing)."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let dest = try await host.requireActiveBrowser().exportPDF(filename: args.filename)
        return .text(dest.path)
    }
}

enum NetworkLogTool: MCPTool {
    struct Args: Decodable { let limit: Int? }
    static let descriptor = ToolDescriptor(
        name: "network_log",
        description: "Return recent fetch/XHR requests observed on the current page via an in-page shim. Captures method, url, status, duration, error. Cleared on navigation.",
        inputSchema: [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "description": "Max entries (newest last). Default 100."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().networkLog(limit: args.limit ?? 100))
    }
}
