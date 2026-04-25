//
//  ActionLog.swift
//  MCP Browser
//
//  Ring buffer of recent MCP tool calls, with export-as-script and
//  in-process replay. Populated by MCPToolRegistry on every call. Not
//  persisted — intentionally session-scoped so the log reflects the
//  current run and doesn't accumulate forever.
//

import Foundation
import Observation

struct ActionLogEntry: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let tool: String
    let argsJSON: String
    let resultPreview: String
    let durationMs: Int
    let isError: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        tool: String,
        argsJSON: String,
        resultPreview: String,
        durationMs: Int,
        isError: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.argsJSON = argsJSON
        self.resultPreview = resultPreview
        self.durationMs = durationMs
        self.isError = isError
    }
}

@MainActor
@Observable
final class ActionLog {
    private(set) var entries: [ActionLogEntry] = []
    private let maxEntries = 500

    func append(_ entry: ActionLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    /// Render the log as a standalone JavaScript script that replays
    /// each call against the local MCP endpoint. Users can paste it
    /// into a Node REPL or run with `node script.js`.
    func exportAsScript(endpoint: String) -> String {
        var lines: [String] = []
        lines.append("// Replay of \(entries.count) MCP Browser tool call(s)")
        lines.append("// Generated \(Date().formatted())")
        lines.append("const endpoint = \(Self.jsString(endpoint));")
        lines.append("""
        async function call(tool, args) {
          const body = {
            jsonrpc: "2.0", id: Date.now(),
            method: "tools/call",
            params: { name: tool, arguments: args }
          };
          const r = await fetch(endpoint, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
          });
          return r.json();
        }
        """)
        lines.append("(async () => {")
        for e in entries where !e.isError {
            lines.append("  console.log(await call(\(Self.jsString(e.tool)), \(e.argsJSON)));")
        }
        lines.append("})();")
        return lines.joined(separator: "\n")
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        var str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        str.removeFirst(); str.removeLast()
        return str
    }
}
