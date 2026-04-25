//
//  ConnectionSettingsView.swift
//  MCP Browser
//
//  The original "how do I connect a client" content, lifted out of
//  SettingsView so each settings tab lives in its own file.
//

import SwiftUI
import AppKit

struct ConnectionSettingsView: View {
    let endpoint: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                clientsSection
            }
            .padding(8)
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MCP SERVER")
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 8))
                Text("Running")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    copy(endpoint)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Text("Any MCP-aware client on this Mac can connect to the browser at the URL above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CONNECT A CLIENT")
            Text("Pick a client to see how to install the browser as an MCP server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            VStack(spacing: 10) {
                ForEach(MCPClientCatalog.all) { client in
                    ClientRow(client: client, endpoint: endpoint, onCopy: copy)
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

private struct ClientRow: View {
    let client: MCPClientInfo
    let endpoint: String
    let onCopy: (String) -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.name).font(.body.weight(.medium))
                    Text(client.configPathHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                Text(client.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                snippetBlock
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var snippetBlock: some View {
        let snippet = client.snippet(endpoint: endpoint)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Snippet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onCopy(snippet)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(snippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
        }
    }
}
