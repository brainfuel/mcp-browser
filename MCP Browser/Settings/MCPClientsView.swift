//
//  MCPClientsView.swift
//  MCP Browser
//
//  Generic Publisher-style client registration list. Pass a server spec
//  and a registrar; this view shows one row per known client with
//  Register / Remove buttons. Same component is intended to drop into
//  Publisher's settings unchanged.
//

import SwiftUI

struct MCPClientsView: View {
    let spec: MCPServerSpec
    let registrar: any MCPRegistrar

    /// Override the default catalog if a host wants to filter / extend.
    var clients: [MCPClient] = MCPClientCatalog.known()

    @State private var installed: [String: Bool] = [:]
    @State private var status: String?
    @State private var isError: Bool = false
    @State private var working: String?
    @State private var hasHomeAccess: Bool = false

    /// Sandboxed builds need a one-time home-folder grant; direct-FS
    /// builds skip the row entirely.
    private var needsHomeFolderGrant: Bool {
        registrar is SecurityScopedRegistrar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsHomeFolderGrant && !hasHomeAccess {
                grantRow
            }
            ForEach(clients) { client in
                MCPClientRow(
                    client: client,
                    installed: installed[client.id] ?? false,
                    busy: working == client.id,
                    onInstall: { perform(client, install: true) },
                    onUninstall: { perform(client, install: false) }
                )
            }
            if let status {
                Label(status, systemImage: isError ? "xmark.octagon.fill" : "checkmark.seal.fill")
                    .foregroundStyle(isError ? Color.red : Color.green)
                    .font(.callout)
                    .padding(.top, 4)
            }
        }
        .onAppear(perform: refresh)
    }

    private var grantRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant home folder access").font(.body.weight(.medium))
                Text("Sandboxed builds need permission to write client config files in your home folder. You'll only be asked once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Grant…") { requestHomeAccess() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func requestHomeAccess() {
        HomeFolderAccess.requestHomeFolderAccess { result in
            Task { @MainActor in
                switch result {
                case .success:
                    hasHomeAccess = true
                    status = nil
                    isError = false
                    refresh()
                case .failure(let error):
                    if HomeFolderAccess.isUserCancellation(error) {
                        status = nil
                    } else {
                        status = error.localizedDescription
                        isError = true
                    }
                }
            }
        }
    }

    private func refresh() {
        if needsHomeFolderGrant {
            hasHomeAccess = ((try? HomeFolderAccess.savedHomeURL()) ?? nil) != nil
        } else {
            hasHomeAccess = true
        }
        installed = Dictionary(uniqueKeysWithValues:
            clients.map { ($0.id, registrar.isInstalled(client: $0, spec: spec)) })
    }

    private func perform(_ client: MCPClient, install: Bool) {
        working = client.id
        status = nil
        Task {
            do {
                if install {
                    let path = try await registrar.install(client: client, spec: spec)
                    status = "Registered with \(client.displayName) → \(path.path). Restart that app."
                    isError = false
                } else {
                    try await registrar.uninstall(client: client, spec: spec)
                    status = "Removed \(spec.name) entry from \(client.displayName)."
                    isError = false
                }
            } catch {
                if HomeFolderAccess.isUserCancellation(error) {
                    status = nil
                } else {
                    status = error.localizedDescription
                    isError = true
                }
            }
            working = nil
            refresh()
        }
    }
}

private struct MCPClientRow: View {
    let client: MCPClient
    let installed: Bool
    let busy: Bool
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? Color.green : Color.secondary)
                .font(.title3)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName).font(.body.weight(.medium))
                Text((client.configPath.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            if busy {
                ProgressView().controlSize(.small)
            } else if installed {
                Button("Remove", role: .destructive) { onUninstall() }
                    .buttonStyle(.bordered)
            } else {
                Button("Register") { onInstall() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
