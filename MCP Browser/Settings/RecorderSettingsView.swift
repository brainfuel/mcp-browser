//
//  RecorderSettingsView.swift
//  MCP Browser
//
//  "Recorder" tab in Settings. Start/stop recording of user actions,
//  review the captured MCP tool-call transcript, clear, and export as
//  a replay script.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecorderSettingsView: View {
    @Environment(Recorder.self) private var recorder
    let endpoint: String

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().padding(.vertical, 8)
            if recorder.steps.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(recorder.steps.enumerated()), id: \.element.id) { index, step in
                        row(index: index + 1, step: step)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if recorder.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Recording")
                        .foregroundStyle(.red)
                        .font(.caption.weight(.semibold))
                }
            } else {
                Text("Stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if recorder.isRecording {
                Button {
                    recorder.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    recorder.start()
                } label: {
                    Label("Start", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Button {
                exportScript()
            } label: {
                Label("Export Script", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .disabled(recorder.steps.isEmpty)

            Button(role: .destructive) {
                recorder.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(recorder.steps.isEmpty)
        }
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No recording yet")
                .font(.body.weight(.medium))
            Text("Click Start, drive the browser manually, then Stop. Your clicks, fills, submits, and navigations will show up here as MCP tool calls.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func row(index: Int, step: RecordedStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index).")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.tool)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    Spacer()
                    Text(step.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(step.argsJSON)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func exportScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.javaScript]
        panel.nameFieldStringValue = "mcp-recording-\(Int(Date().timeIntervalSince1970)).js"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let script = recorder.exportAsScript(endpoint: endpoint)
            try? script.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }
}
