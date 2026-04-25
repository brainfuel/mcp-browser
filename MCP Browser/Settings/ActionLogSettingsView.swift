//
//  ActionLogSettingsView.swift
//  MCP Browser
//
//  "Action Log" tab in Settings: a timeline of recent MCP tool calls
//  with export-as-replay-script and a one-click replay that re-plays
//  each recorded call against the local endpoint.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActionLogSettingsView: View {
    @Environment(ActionLog.self) private var log
    let endpoint: String

    @State private var replayStatus: String?
    @State private var isReplaying = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().padding(.vertical, 8)
            if log.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(log.entries.reversed()) { entry in
                        row(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var controls: some View {
        HStack {
            if let replayStatus {
                Text(replayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                exportScript()
            } label: {
                Label("Export Script", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(log.entries.isEmpty)

            Button {
                Task { await replay() }
            } label: {
                Label(isReplaying ? "Replaying…" : "Replay", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(log.entries.isEmpty || isReplaying)

            Button(role: .destructive) {
                log.clear()
                replayStatus = nil
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(log.entries.isEmpty)
        }
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No MCP calls yet")
                .font(.body.weight(.medium))
            Text("Anything an MCP client does will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func row(_ entry: ActionLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "chevron.right.circle.fill")
                    .foregroundStyle(entry.isError ? .red : .accentColor)
                Text(entry.tool)
                    .font(.system(.body, design: .monospaced).weight(.medium))
                Spacer()
                Text("\(entry.durationMs) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.argsJSON)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
            if !entry.resultPreview.isEmpty {
                Text(entry.resultPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Export

    private func exportScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.javaScript]
        panel.nameFieldStringValue = "mcp-replay-\(Int(Date().timeIntervalSince1970)).js"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let script = log.exportAsScript(endpoint: endpoint)
            try? script.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    // MARK: - Replay

    /// Replays each logged tool call by POSTing it to the local MCP
    /// endpoint, one at a time. Errors don't abort — we report counts.
    private func replay() async {
        isReplaying = true
        defer { isReplaying = false }
        var ok = 0
        var fail = 0
        let entries = log.entries
        for (i, entry) in entries.enumerated() where !entry.isError {
            replayStatus = "Replaying \(i + 1) / \(entries.count): \(entry.tool)"
            let success = await post(tool: entry.tool, argsJSON: entry.argsJSON)
            if success { ok += 1 } else { fail += 1 }
        }
        replayStatus = "Replay done — \(ok) ok, \(fail) failed."
    }

    private func post(tool: String, argsJSON: String) async -> Bool {
        guard let endpointURL = URL(string: endpoint) else { return false }
        let argsValue = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) ?? [:]
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int(Date().timeIntervalSince1970 * 1000),
            "method": "tools/call",
            "params": ["name": tool, "arguments": argsValue]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            return false
        }
        var req = URLRequest(url: endpointURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
