//
//  CookieTools.swift
//  MCP Browser
//

import Foundation

enum GetCookiesTool: MCPTool {
    struct Args: Decodable { let domain: String? }
    static let descriptor = ToolDescriptor(
        name: "get_cookies",
        description: "Return cookies from the browser's shared store. Optionally filter by domain (suffix match).",
        inputSchema: [
            "type": "object",
            "properties": ["domain": ["type": "string"]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let cookies = await (try host.requireActiveBrowser()).getCookies(domain: args.domain)
        let payload: [[String: Any]] = cookies.map { c in
            var d: [String: Any] = [
                "name": c.name,        "value": c.value,
                "domain": c.domain,    "path": c.path,
                "secure": c.isSecure,  "httpOnly": c.isHTTPOnly,
                "session": c.isSessionOnly
            ]
            if let exp = c.expiresDate { d["expires"] = exp.timeIntervalSince1970 }
            return d
        }
        return .json(payload)
    }
}

enum SetCookieTool: MCPTool {
    struct Args: Decodable {
        let name: String
        let value: String
        let domain: String
        let path: String?
        let secure: Bool?
        let httpOnly: Bool?
        let expires: Double?
    }
    static let descriptor = ToolDescriptor(
        name: "set_cookie",
        description: "Insert or update a cookie in the browser's shared store.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name":     ["type": "string"],
                "value":    ["type": "string"],
                "domain":   ["type": "string"],
                "path":     ["type": "string", "description": "Default '/'."],
                "secure":   ["type": "boolean"],
                "httpOnly": ["type": "boolean"],
                "expires":  ["type": "number", "description": "Unix epoch seconds. Omit for session cookie."]
            ],
            "required": ["name", "value", "domain"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name:   args.name,
            .value:  args.value,
            .domain: args.domain,
            .path:   args.path ?? "/"
        ]
        if args.secure == true { props[.secure] = "TRUE" }
        if let exp = args.expires { props[.expires] = Date(timeIntervalSince1970: exp) }
        guard let cookie = HTTPCookie(properties: props) else {
            throw RPCError(code: -32602, message: "invalid cookie properties")
        }
        await (try host.requireActiveBrowser()).setCookie(cookie)
        return .text("set")
    }
}

enum StorageTool: MCPTool {
    struct Args: Decodable {
        let kind: String
        let op: String
        let key: String?
        let value: String?
    }
    static let descriptor = ToolDescriptor(
        name: "storage",
        description: "Read or write the current page's localStorage or sessionStorage. `kind` is \"local\" or \"session\". `op` is one of: get, set, remove, clear, keys. `get` without a key returns all entries.",
        inputSchema: [
            "type": "object",
            "properties": [
                "kind":  ["type": "string", "enum": ["local", "session"]],
                "op":    ["type": "string", "enum": ["get", "set", "remove", "clear", "keys"]],
                "key":   ["type": "string", "description": "Required for set/remove. Optional for get."],
                "value": ["type": "string", "description": "Required for set."]
            ],
            "required": ["kind", "op"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard let kind = BrowserTab.StorageKind(rawValue: args.kind) else {
            throw RPCError(code: -32602, message: "invalid `kind` (expected local|session)")
        }
        guard let op = BrowserTab.StorageOp(rawValue: args.op) else {
            throw RPCError(code: -32602, message: "invalid `op` (expected get|set|remove|clear|keys)")
        }
        let result = try await host.requireActiveBrowser().storage(
            kind: kind, op: op, key: args.key, value: args.value
        )
        return .json(result ?? NSNull())
    }
}

enum ClearSessionTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "clear_session",
        description: "Clear cookies, localStorage, and all website data for every origin. Destructive — use with intent."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        await (try host.requireActiveBrowser()).clearSession()
        return .text("cleared")
    }
}
