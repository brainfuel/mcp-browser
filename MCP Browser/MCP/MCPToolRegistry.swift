//
//  MCPToolRegistry.swift
//  MCP Browser
//
//  JSON-RPC + MCP method dispatch for the tool-only subset:
//  `initialize`, `tools/list`, `tools/call`, `notifications/initialized`.
//
//  The actual tool surface lives in `MCPToolCatalog`; this file owns
//  request lifecycle, side effects (cursor / PiP / log), and
//  JSON-RPC encoding.
//

import Foundation

/// Bridge between the off-main networking queue and the main-actor
/// host. The registry itself is `nonisolated`; tool bodies hop to
/// `@MainActor` for each WebKit call.
nonisolated final class MCPToolRegistry: @unchecked Sendable {

    /// Single dependency surface — replaces five separate resolvers.
    /// Closure form lets us hold the `@MainActor` host lazily without
    /// making the registry main-actor-isolated itself.
    private let host: @Sendable @MainActor () -> (any MCPHost)?

    /// Tool names whose first selector argument should flash the agent
    /// cursor before executing. Derived once at startup.
    private static let selectorToolNames: Set<String> = [
        "click", "fill", "submit", "scroll", "get_element", "upload_file"
    ]

    init(host: @escaping @Sendable @MainActor () -> (any MCPHost)?) {
        self.host = host
    }

    // MARK: - HTTP entry point

    /// Entry from MCPServer. Always returns valid JSON-RPC bytes.
    func handle(jsonRPCBody body: Data) async -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return encode(error: -32700, message: "parse error", id: .null)
        }
        let id = RPCID(any: root["id"])
        let method = root["method"] as? String ?? ""
        let params = root["params"] as? [String: Any] ?? [:]
        let isNotification = root["id"] == nil

        do {
            let result = try await dispatch(method: method, params: params)
            if isNotification { return Data() }
            return encode(result: result, id: id)
        } catch let e as RPCError {
            return encode(error: e.code, message: e.message, id: id)
        } catch {
            return encode(error: -32603,
                          message: "internal error: \(error.localizedDescription)",
                          id: id)
        }
    }

    // MARK: - Method dispatch

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            return [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo":   ["name": "MCP Browser", "version": "0.1.0"],
                "instructions": "Drive a persistent WKWebView: navigate, read page text, take screenshots, run JavaScript."
            ]

        case "notifications/initialized":
            return [String: Any]()  // ignored notification

        case "tools/list":
            return await MainActor.run { ["tools": MCPToolCatalog.descriptors] }

        case "tools/call":
            return try await handleToolCall(params: params)

        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    /// `tools/call` wrapper: pulls name/args, runs cursor pre-flash,
    /// dispatches via the catalog, logs, refreshes PiP.
    private func handleToolCall(params: [String: Any]) async throws -> Any {
        guard let name = params["name"] as? String else {
            throw RPCError(code: -32602, message: "missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        await flashAgentCursorIfApplicable(toolName: name, args: args)

        let started = Date()
        do {
            let output = try await runTool(name: name, args: args)
            await log(tool: name, args: args, result: output.asDictionary, startedAt: started, isError: output.isError)
            await updatePipIfEnabled()
            return output.asDictionary
        } catch {
            await log(tool: name, args: args,
                      result: ["error": String(describing: error)] as [String: Any],
                      startedAt: started, isError: true)
            throw error
        }
    }

    /// Resolve a tool by name and execute it on the main actor.
    private func runTool(name: String, args: [String: Any]) async throws -> ToolOutput {
        try await MainActor.run {
            (try MCPToolCatalog.tool(named: name), try self.requireHost())
        } |> { (tool, host) in
            try await tool.run(args, host)
        }
    }

    @MainActor
    private func requireHost() throws -> any MCPHost {
        guard let h = host() else {
            throw RPCError(code: -32000, message: "no active browser window")
        }
        return h
    }

    // MARK: - Side effects

    /// Briefly flash the agent cursor on selector-based tools when
    /// enabled. Fire-and-forget; the tool call itself isn't delayed.
    private func flashAgentCursorIfApplicable(toolName: String, args: [String: Any]) async {
        guard Self.selectorToolNames.contains(toolName),
              let selector = args["selector"] as? String, !selector.isEmpty else { return }
        await MainActor.run {
            guard let h = self.host(),
                  h.agentSettings.cursorEnabled,
                  let browser = h.activeBrowser else { return }
            Task { await browser.highlightSelector(selector) }
        }
    }

    /// If PiP is on, snapshot the active tab and push it into the panel.
    private func updatePipIfEnabled() async {
        let target: (PipController, BrowserTab)? = await MainActor.run {
            guard let h = self.host(),
                  h.agentSettings.pipEnabled,
                  let browser = h.activeBrowser else { return nil }
            return (h.pip, browser)
        }
        guard let (pip, browser) = target,
              let data = try? await browser.screenshotPNG() else { return }
        await MainActor.run { pip.updateFrame(pngData: data) }
    }

    /// Append a tool call to the shared ActionLog. No-op if no host.
    private func log(tool: String, args: [String: Any], result: Any,
                     startedAt: Date, isError: Bool) async {
        let argsJSON = JSONHelpers.stringify(args)
        let preview = String(JSONHelpers.stringify(result).prefix(500))
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        await MainActor.run {
            guard let log = self.host()?.actionLog else { return }
            log.append(ActionLogEntry(
                tool: tool, argsJSON: argsJSON, resultPreview: preview,
                durationMs: durationMs, isError: isError
            ))
        }
    }

    // MARK: - Encoding

    private func encode(result: Any, id: RPCID) -> Data {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id.jsonValue, "result": result]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data()
    }

    private func encode(error code: Int, message: String, id: RPCID) -> Data {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id.jsonValue,
            "error": ["code": code, "message": message]
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [])) ?? Data()
    }
}

// MARK: - Tiny pipeline helper

/// Pipe-forward operator used in `runTool` so the two-step "resolve on
/// main, then run" reads top-down. Local to this file.
infix operator |> : AdditionPrecedence

private func |> <A, B>(value: A, transform: (A) async throws -> B) async rethrows -> B {
    try await transform(value)
}
