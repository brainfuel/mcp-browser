//
//  DownloadsPopover.swift
//  MCP Browser
//
//  Toolbar popover listing user-initiated downloads — running ones show
//  a progress bar; finished ones offer "Show in Finder" and "Open".
//

import SwiftUI

struct DownloadsPopover: View {
    @Bindable var store: DownloadStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.items.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.items) { item in
                            DownloadRow(item: item, store: store)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("Downloads").font(.headline)
            Spacer()
            if store.items.contains(where: { isClearable($0) }) {
                Button("Clear") { store.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No downloads")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func isClearable(_ item: DownloadItem) -> Bool {
        switch item.state {
        case .finished, .failed, .cancelled: return true
        case .running: return false
        }
    }
}

private struct DownloadRow: View {
    @Bindable var item: DownloadItem
    let store: DownloadStore

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.state {
        case .running:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "doc")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch item.state {
        case .running:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                Text(progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .finished:
            Text(byteCountLabel(item.totalBytes > 0 ? item.totalBytes : item.receivedBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .running:
            Button { store.cancel(id: item.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .finished:
            Button { store.openFile(item) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("Open")
            Button { store.revealInFinder(item) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        case .failed, .cancelled:
            Button { store.remove(id: item.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }

    private var progressValue: Double {
        item.totalBytes > 0
            ? Double(item.receivedBytes) / Double(item.totalBytes)
            : item.fractionCompleted
    }

    private var progressLabel: String {
        if item.totalBytes > 0 {
            return "\(byteCountLabel(item.receivedBytes)) of \(byteCountLabel(item.totalBytes))"
        }
        return byteCountLabel(item.receivedBytes)
    }

    private func byteCountLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
