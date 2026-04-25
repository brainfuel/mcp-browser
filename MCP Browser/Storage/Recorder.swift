//
//  Recorder.swift
//  MCP Browser
//
//  Captures user interactions (click / fill / submit / navigate) as a
//  sequence of MCP tool-call entries. Paired with a WKUserScript that
//  listens for DOM events when `window.__mcpRecording` is true and
//  posts them to the native handler.
//
//  Session-scoped — start/stop/clear live in memory, while export
//  emits a standalone replay script (same shape as ActionLog).
//

import Foundation
import Observation

struct RecordedStep: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let tool: String
    let argsJSON: String

    init(id: UUID = UUID(), timestamp: Date = .now, tool: String, argsJSON: String) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.argsJSON = argsJSON
    }
}

@MainActor
@Observable
final class Recorder {
    private(set) var isRecording: Bool = false
    private(set) var steps: [RecordedStep] = []

    /// Collapse rapid repeated `fill` events on the same selector —
    /// keyboard changes fire `change` on blur but apps sometimes
    /// dispatch it repeatedly; we want one fill per final value.
    private let fillCoalesceWindow: TimeInterval = 0.1

    /// Wired by MCPCoordinator so toggling `start`/`stop` pushes the
    /// flag into every open tab's page.
    var onStateChange: ((Bool) -> Void)?

    func start() {
        steps.removeAll()
        isRecording = true
        onStateChange?(true)
    }

    func stop() {
        isRecording = false
        onStateChange?(false)
    }

    func clear() {
        steps.removeAll()
    }

    /// Ingest a raw event from the in-page listener. Coalesces sequential
    /// fills on the same selector so a single typed field produces one
    /// `fill` step rather than N.
    func ingest(tool: String, args: [String: Any]) {
        guard isRecording else { return }
        let json = encode(args)
        // Coalesce fills
        if tool == "fill",
           let last = steps.last,
           last.tool == "fill",
           sameSelector(last.argsJSON, json),
           Date().timeIntervalSince(last.timestamp) < fillCoalesceWindow {
            steps[steps.count - 1] = RecordedStep(tool: tool, argsJSON: json)
            return
        }
        steps.append(RecordedStep(tool: tool, argsJSON: json))
    }

    /// Record a manual navigate (user typed a URL or clicked a bookmark).
    func recordManualNavigate(url: String) {
        ingest(tool: "navigate", args: ["url": url])
    }

    /// JavaScript replay script that POSTs each recorded step to the
    /// local MCP endpoint in order. Same shape as ActionLog exports.
    func exportAsScript(endpoint: String) -> String {
        var lines: [String] = []
        lines.append("// MCP Browser recording — \(steps.count) step(s)")
        lines.append("// Captured \(Date().formatted())")
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
        for s in steps {
            lines.append("  console.log(await call(\(Self.jsString(s.tool)), \(s.argsJSON)));")
        }
        lines.append("})();")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func encode(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private func sameSelector(_ a: String, _ b: String) -> Bool {
        func selector(_ s: String) -> String? {
            let data = Data(s.utf8)
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return obj?["selector"] as? String
        }
        return selector(a) != nil && selector(a) == selector(b)
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        var str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        str.removeFirst(); str.removeLast()
        return str
    }
}
