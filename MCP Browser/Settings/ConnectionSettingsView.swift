//
//  ConnectionSettingsView.swift
//  MCP Browser
//
//  Shows the running MCP HTTP endpoint plus a list of well-known MCP
//  clients. Each row offers one-click Register / Remove via the shared
//  `MCPClientsView` (drives a `SecurityScopedRegistrar` because the
//  app is sandboxed).
//

import SwiftUI
import AppKit

struct ConnectionSettingsView: View {
    @Environment(MCPCoordinator.self) private var coordinator
    let endpoint: String

    @State private var registrar: any MCPRegistrar = MCPRegistrarFactory.makeDefault()
    @State private var tokenRevealed = false
    @State private var tokenVersion = 0   // bumped to force view refresh after regen

    private var spec: MCPServerSpec {
        MCPServerSpec(
            name: "mcp-browser",
            transport: .http(
                url: endpoint,
                headers: ["Authorization": "Bearer \(MCPSecret.token)"]
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                tokenSection
                clientsSection
            }
            .padding(8)
        }
    }

    // MARK: - Token section

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ACCESS TOKEN")
            Text("Clients must send this token in an `Authorization: Bearer …` header. Registering a client through the buttons below writes it for you. Regenerate to revoke access for every client at once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(tokenRevealed ? MCPSecret.token : String(repeating: "•", count: 24))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .id(tokenVersion)
                Spacer()
                Button(tokenRevealed ? "Hide" : "Reveal") {
                    tokenRevealed.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    copy(MCPSecret.token)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Regenerate") {
                    MCPSecret.regenerate()
                    tokenVersion &+= 1
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Server section

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MCP SERVER")
            HStack {
                Image(systemName: "circle.fill")
                    .foregroundStyle(serverStatusColor)
                    .font(.system(size: 8))
                Text(serverStatusTitle)
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
            if let detail = serverStatusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(serverStatusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Clients section

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CONNECT A CLIENT")
            Text("Register MCP Browser with any of these tools — they'll be able to drive the browser the next time you launch them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            MCPClientsView(spec: spec, registrar: registrar)
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private var serverStatusTitle: String {
        switch coordinator.serverState {
        case .stopped:  return "Stopped"
        case .starting: return "Starting…"
        case .running:  return "Running"
        case .failed:   return "Failed"
        }
    }

    private var serverStatusDetail: String? {
        switch coordinator.serverState {
        case .failed(let message):     return message
        case .stopped:                 return "The MCP server is not listening right now."
        case .starting, .running:      return nil
        }
    }

    private var serverStatusColor: Color {
        switch coordinator.serverState {
        case .running:  return .green
        case .starting: return .orange
        case .failed:   return .red
        case .stopped:  return .secondary
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
