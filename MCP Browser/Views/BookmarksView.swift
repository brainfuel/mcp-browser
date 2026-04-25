//
//  BookmarksView.swift
//  MCP Browser
//

import SwiftUI

struct BookmarksView: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.barChildren.isEmpty && offBarBookmarks.isEmpty {
                emptyState
            } else {
                List {
                    Section("Bookmarks Bar") {
                        ForEach(store.barChildren) { node in
                            barNodeRow(node)
                        }
                    }
                    if !offBarBookmarks.isEmpty {
                        Section("Other") {
                            ForEach(offBarBookmarks) { bm in
                                bookmarkRow(for: bm)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Bookmarks")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                store.createFolder(name: "New Folder", parentID: store.barFolderID)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bookmark")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No bookmarks yet")
                .font(.body.weight(.medium))
            Text("Tap the star next to the address bar to save the current page.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// Bookmarks not in the bar folder and not inside any folder.
    private var offBarBookmarks: [Bookmark] {
        store.bookmarks.filter { $0.parentID == nil }
    }

    /// Folders that live on the bar (one level deep), used to populate
    /// the "Move to" picker on each bookmark row.
    private var barFolders: [BookmarkFolder] {
        store.barChildren.compactMap {
            if case .folder(let f) = $0 { return f } else { return nil }
        }
    }

    @ViewBuilder
    private func barNodeRow(_ node: BookmarkNode) -> some View {
        switch node {
        case .bookmark(let b):
            bookmarkRow(for: b)
        case .folder(let f):
            folderGroup(f)
        }
    }

    @ViewBuilder
    private func folderGroup(_ folder: BookmarkFolder) -> some View {
        FolderDisclosure(folder: folder, barFolders: barFolders) { bookmark in
            bookmarkRow(for: bookmark)
        }
    }

    private func bookmarkRow(for bookmark: Bookmark) -> some View {
        BookmarkRow(
            bookmark: bookmark,
            barFolders: barFolders,
            barFolderID: store.barFolderID,
            onOpen: {
                browser.navigate(to: bookmark.url)
                dismiss()
            },
            onRename: { newTitle in
                store.rename(id: bookmark.id, title: newTitle)
            },
            onMove: { destination in
                store.move(id: bookmark.id, to: destination)
            },
            onRemove: {
                store.remove(id: bookmark.id)
            }
        )
    }
}

// MARK: - Folder disclosure

private struct FolderDisclosure<Row: View>: View {
    @Environment(BookmarkStore.self) private var store

    let folder: BookmarkFolder
    let barFolders: [BookmarkFolder]
    @ViewBuilder var row: (Bookmark) -> Row

    @State private var expanded = true
    @State private var draftName: String = ""
    @State private var isTargeted = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            let kids = store.children(of: folder.id)
            if kids.isEmpty {
                Text("Empty")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else {
                ForEach(kids) { node in
                    if case .bookmark(let b) = node {
                        row(b)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.yellow)
                TextField("Folder", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                Spacer()
                Button(role: .destructive) {
                    store.remove(id: folder.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete folder and its bookmarks")
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .onAppear { draftName = folder.name }
        .onChange(of: folder.name) { _, newValue in
            if !nameFocused { draftName = newValue }
        }
        .dropDestination(for: BookmarkDragPayload.self) { items, _ in
            guard let payload = items.first, payload.id != folder.id else { return false }
            store.move(id: payload.id, to: folder.id)
            return true
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: PageDragPayload.self) { items, _ in
            guard let page = items.first, !page.url.isEmpty else { return false }
            store.add(title: page.title, url: page.url, parentID: folder.id)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func commitRename() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != folder.name else { return }
        store.renameFolder(id: folder.id, name: trimmed)
    }
}

// MARK: - Bookmark row

/// One bookmark row. Title is inline-editable; the "Move to" menu lets
/// the user reparent the bookmark to the bar root, any bar folder, or
/// off-bar without dragging.
private struct BookmarkRow: View {
    let bookmark: Bookmark
    let barFolders: [BookmarkFolder]
    let barFolderID: UUID
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onMove: (UUID?) -> Void
    let onRemove: () -> Void

    @State private var draftTitle: String = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                Text(bookmark.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen() }
            }

            Spacer()

            Menu {
                Button {
                    onMove(barFolderID)
                } label: {
                    Label("Bar", systemImage: currentParent == barFolderID ? "checkmark" : "star")
                }
                if !barFolders.isEmpty {
                    Divider()
                    ForEach(barFolders) { folder in
                        Button {
                            onMove(folder.id)
                        } label: {
                            Label(folder.name,
                                  systemImage: currentParent == folder.id ? "checkmark" : "folder")
                        }
                    }
                }
                Divider()
                Button {
                    onMove(nil)
                } label: {
                    Label("Off bar", systemImage: currentParent == nil ? "checkmark" : "tray")
                }
            } label: {
                Text(locationLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Move bookmark")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove bookmark")
        }
        .draggable(BookmarkDragPayload(id: bookmark.id))
        .onAppear { draftTitle = bookmark.title }
        .onChange(of: bookmark.title) { _, newValue in
            if !titleFocused { draftTitle = newValue }
        }
    }

    private var currentParent: UUID? { bookmark.parentID }

    private var locationLabel: String {
        if let pid = bookmark.parentID {
            if pid == barFolderID { return "Bar" }
            return barFolders.first(where: { $0.id == pid })?.name ?? "Folder"
        }
        return "Off bar"
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != bookmark.title else { return }
        onRename(trimmed)
    }
}
