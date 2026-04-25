//
//  BookmarksSettingsView.swift
//  MCP Browser
//
//  Bookmarks-management tab: import from a browser export
//  (Safari / Chrome / Firefox / Edge HTML bookmarks file).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BookmarksSettingsView: View {
    @Environment(BookmarkStore.self) private var store
    @State private var lastResult: String?
    @State private var error: String?
    @State private var isImporting = false
    @State private var showingClearConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                importCard
                statsCard
            }
            .padding(8)
        }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("IMPORT")
            Text("Import bookmarks from a Safari, Chrome, Firefox, or Edge export. Pick the .html file directly, or the .zip from Safari's \"Export Browsing Data to File\" (we'll unzip it for you).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    pickAndImport()
                } label: {
                    Label(isImporting ? "Importing…" : "Import bookmarks…",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImporting)
                Spacer()
            }
            if let lastResult {
                resultBanner(lastResult)
            }
            if let error {
                errorBanner(error)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CURRENT")
            HStack {
                Text("\(store.bookmarks.count) bookmark\(store.bookmarks.count == 1 ? "" : "s"), \(store.barBookmarks.count) pinned to the bar.")
                    .font(.body)
                Spacer()
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(store.bookmarks.isEmpty)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .confirmationDialog(
            "Delete all bookmarks?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.bookmarks.count) Bookmark\(store.bookmarks.count == 1 ? "" : "s")",
                   role: .destructive) {
                store.clearAll()
                lastResult = nil
                error = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every bookmark and unpins everything from the bar. This action can't be undone.")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html, .zip]
        panel.title = "Choose a bookmarks export"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                isImporting = true
                defer { isImporting = false }
                do {
                    let result = try BookmarkImporter.import(from: url, into: store)
                    lastResult = "Added \(result.added), skipped \(result.skipped)."
                    error = nil
                } catch let e {
                    lastResult = nil
                    error = e.localizedDescription
                }
            }
        }
    }
}
