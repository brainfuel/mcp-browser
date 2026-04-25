//
//  MCPTool.swift
//  MCP Browser
//
//  Typed protocol for MCP tool implementations. Each tool declares its
//  decoded `Args`, descriptor, and an `execute(_:host:)` body. The
//  registry decodes JSON args via JSONDecoder and dispatches by name —
//  no stringly-typed `args["x"] as? String, !s.isEmpty` boilerplate.
//

import Foundation

// MARK: - Descriptor

/// MCP `tools/list` entry. `inputSchema` round-trips as JSON and is
/// kept as `[String: Any]` because that's what the protocol expects on
/// the wire — we don't gain anything by re-parsing it Swift-side.
struct ToolDescriptor {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    init(name: String, description: String, inputSchema: [String: Any] = ["type": "object", "properties": [String: Any]()]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var asDictionary: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

// MARK: - Output envelope

/// MCP `tools/call` response shape. The two factories cover every tool
/// we have today (text body or PNG image).
struct ToolOutput {
    var content: [Content]
    var isError: Bool

    enum Content {
        case text(String)
        case image(base64: String, mime: String)

        fileprivate var asDictionary: [String: Any] {
            switch self {
            case .text(let s):
                return ["type": "text", "text": s]
            case .image(let b64, let mime):
                return ["type": "image", "data": b64, "mimeType": mime]
            }
        }
    }

    static func text(_ s: String, isError: Bool = false) -> ToolOutput {
        ToolOutput(content: [.text(s)], isError: isError)
    }

    static func json(_ any: Any?, isError: Bool = false) -> ToolOutput {
        .text(JSONHelpers.stringify(any), isError: isError)
    }

    static func image(_ data: Data, mime: String = "image/png") -> ToolOutput {
        ToolOutput(content: [.image(base64: data.base64EncodedString(), mime: mime)], isError: false)
    }

    var asDictionary: [String: Any] {
        ["content": content.map(\.asDictionary), "isError": isError]
    }
}

// MARK: - Tool protocol

/// A single MCP tool. Each tool is a tiny type that knows its own
/// descriptor and body. Args decode from a JSON dictionary via
/// `JSONDecoder`; use `EmptyArgs` for tools that take none.
@MainActor
protocol MCPTool {
    associatedtype Args: Decodable

    static var descriptor: ToolDescriptor { get }
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput
}

/// Sentinel for tools that take no arguments. JSON decoding of `{}`
/// or any object succeeds because the type ignores all keys.
struct EmptyArgs: Decodable {}

// MARK: - Type erasure

/// Runtime-polymorphic wrapper around `MCPTool.Type`. Lets the registry
/// hold a homogeneous catalog and dispatch via a single closure.
struct AnyMCPTool {
    let descriptor: ToolDescriptor
    let run: @MainActor ([String: Any], any MCPHost) async throws -> ToolOutput

    init<T: MCPTool>(_ type: T.Type) {
        self.descriptor = T.descriptor
        self.run = { rawArgs, host in
            let args = try JSONHelpers.decode(T.Args.self, from: rawArgs)
            return try await T.execute(args, host: host)
        }
    }
}

// MARK: - JSON helpers

enum JSONHelpers {

    /// Decode a Swift-side `[String: Any]` dictionary into a Decodable
    /// type via a JSONSerialization round-trip. Tool args arrive as
    /// `[String: Any]` from JSONSerialization at the HTTP layer.
    static func decode<T: Decodable>(_ type: T.Type, from raw: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Render an arbitrary JSON-ish value as a sorted-key string.
    /// Used by tools that return free-form data (list_links, cookies…).
    static func stringify(_ any: Any?) -> String {
        guard let any, !(any is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        if let s = any as? String,
           let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
           var str = String(data: data, encoding: .utf8) {
            str.removeFirst(); str.removeLast()
            return str
        }
        return String(describing: any)
    }
}
