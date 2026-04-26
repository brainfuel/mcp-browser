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
    @Environment(MCPCoordinator.self) private var coordinator
    let endpoint: String
    @State private var codexInstaller = CodexInstaller()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverSection
                codexSection
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

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CODEX")
            Text("Install or refresh a home-local Codex plugin for MCP Browser. The first time, choose your home folder so the sandbox can write ~/plugins and ~/.agents for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let path = codexInstaller.savedHomePath {
                HStack(spacing: 8) {
                    Image(systemName: codexInstaller.isInstalled ? "checkmark.circle.fill" : "folder.fill")
                        .foregroundStyle(codexInstaller.isInstalled ? Color.green : Color.secondary)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    codexInstaller.install(endpoint: endpoint)
                } label: {
                    Label(codexInstaller.isInstalling
                          ? "Installing…"
                          : (codexInstaller.isInstalled ? "Reinstall in Codex" : "Install in Codex…"),
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(codexInstaller.isInstalling)

                Button {
                    codexInstaller.chooseHomeFolder()
                } label: {
                    Label(codexInstaller.hasSavedHomeFolder ? "Change Folder…" : "Choose Folder…",
                          systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if codexInstaller.isInstalled {
                    Button {
                        codexInstaller.revealPluginInFinder()
                    } label: {
                        Label("Reveal Plugin", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            if let lastResult = codexInstaller.lastResult {
                resultBanner(lastResult)
            }
            if let error = codexInstaller.errorMessage {
                errorBanner(error)
            }
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

    private var serverStatusTitle: String {
        switch coordinator.serverState {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting…"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    private var serverStatusDetail: String? {
        switch coordinator.serverState {
        case .failed(let message):
            return message
        case .stopped:
            return "The MCP server is not listening right now."
        case .starting, .running:
            return nil
        }
    }

    private var serverStatusColor: Color {
        switch coordinator.serverState {
        case .running:
            return .green
        case .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func resultBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout.weight(.medium))
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.10))
        )
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.10))
        )
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
