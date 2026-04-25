//
//  BookmarksView.swift
//  MCP Browser
//

import SwiftUI

struct BookmarksView: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser
    @Environment(\.dismiss) private var dismiss

    @State private var dragHover = BookmarkDragHover()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.barChildren.isEmpty && offBarBookmarks.isEmpty {
                emptyState
            } else {
                List {
                    Section("Bookmarks Bar") {
                        ForEach(Array(store.barChildren.enumerated()), id: \.element.id) { index, node in
                            reorderableRow(parentID: store.barFolderID, index: index) {
                                barNodeRow(node)
                            }
                        }
                        ReorderableTailGap(
                            parentID: store.barFolderID,
                            insertIndex: store.barChildren.count,
                            onDropInsert: animatedMove
                        )
                    }
                    if !offBarBookmarks.isEmpty {
                        Section("Other") {
                            ForEach(Array(offBarBookmarks.enumerated()), id: \.element.id) { index, bookmark in
                                reorderableRow(parentID: nil, index: index) {
                                    bookmarkRow(for: bookmark)
                                }
                            }
                            ReorderableTailGap(
                                parentID: nil,
                                insertIndex: offBarBookmarks.count,
                                onDropInsert: animatedMove
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 560, height: 520)
        .environment(dragHover)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Bookmarks")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    let id = store.createFolder(name: "New Folder", parentID: store.barFolderID)
                    store.move(id: id, to: store.barFolderID, index: 0)
                }
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
        FolderDisclosure(folder: folder) { bookmark, childIndex in
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

    private func animatedMove(_ draggedID: UUID, _ newParent: UUID?, _ newIndex: Int) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            store.move(id: draggedID, to: newParent, index: newIndex)
        }
    }

    private func reorderableRow<Content: View>(
        parentID: UUID?,
        index: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ReorderableRowHost(parentID: parentID, index: index) { draggedID, newParent, newIndex in
            animatedMove(draggedID, newParent, newIndex)
        } content: {
            content()
        }
    }
}

// MARK: - Folder disclosure

private struct FolderDisclosure<Row: View>: View {
    @Environment(BookmarkStore.self) private var store

    let folder: BookmarkFolder
    @ViewBuilder var row: (Bookmark, Int) -> Row

    @State private var expanded = true
    @State private var draftName: String = ""
    @State private var isFolderTargeted = false
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
                ForEach(Array(kids.enumerated()), id: \.element.id) { childIndex, node in
                    if case .bookmark(let b) = node {
                        ReorderableRowHost(parentID: folder.id, index: childIndex) { draggedID, newParent, newIndex in
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                store.move(id: draggedID, to: newParent, index: newIndex)
                            }
                        } content: {
                            row(b, childIndex)
                        }
                    }
                }
                ReorderableTailGap(
                    parentID: folder.id,
                    insertIndex: kids.count
                ) { draggedID, newParent, newIndex in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        store.move(id: draggedID, to: newParent, index: newIndex)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.yellow)
                    .contentShape(Rectangle())
                    .draggable(BookmarkDragPayload(id: folder.id))
                    .help("Drag to move folder")
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
                    .fill(isFolderTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .onAppear { draftName = folder.name }
        .onChange(of: folder.name) { _, newValue in
            if !nameFocused { draftName = newValue }
        }
        .dropDestination(for: BookmarkDragPayload.self) { items, _ in
            guard let payload = items.first, payload.id != folder.id else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.move(id: payload.id, to: folder.id)
            }
            return true
        } isTargeted: { isFolderTargeted = $0 }
        .dropDestination(for: PageDragPayload.self) { items, _ in
            guard let page = items.first, !page.url.isEmpty else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.add(title: page.title, url: page.url, parentID: folder.id)
            }
            return true
        } isTargeted: { isFolderTargeted = $0 }
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

/// Identifies one insertion slot between (or at the edges of) sibling
/// rows. The slot directly above row N is `(parentID, N)`; the slot at
/// the end of a section/folder is `(parentID, count)`.
struct InsertionTarget: Hashable {
    let parentID: UUID?
    let insertIndex: Int
}

/// Shared drag-hover state for the bookmarks management sheet. Lifted
/// out of individual rows so that hovering the bottom half of row N and
/// the top half of row N+1 both light up the same insertion gap (they
/// target the same slot — `(parent, N+1)`). Tracked as a refcount so a
/// transition between adjacent halves doesn't briefly clear the active
/// slot during the cross-over.
@MainActor
@Observable
final class BookmarkDragHover {
    @ObservationIgnored
    private var refs: [InsertionTarget: Int] = [:]
    private(set) var active: InsertionTarget?

    /// Pending "clear" task. When all refs drop to zero we don't clear
    /// `active` immediately — animation reflows can briefly knock the
    /// cursor out of every drop target as the gap opens, and we want
    /// the slot to stay highlighted across that gap. If a new hover
    /// arrives in the meantime the task is cancelled.
    @ObservationIgnored
    private var clearTask: Task<Void, Never>?

    private static let clearDelay: Duration = .milliseconds(140)

    func setHovering(_ target: InsertionTarget, _ hovering: Bool) {
        let next = (refs[target] ?? 0) + (hovering ? 1 : -1)
        if next <= 0 {
            refs.removeValue(forKey: target)
        } else {
            refs[target] = next
        }

        if let live = refs.first(where: { $0.value > 0 })?.key {
            clearTask?.cancel()
            clearTask = nil
            if live != active { active = live }
        } else if active != nil {
            scheduleClear()
        }
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.clearDelay)
            guard let self, !Task.isCancelled else { return }
            if self.refs.values.allSatisfy({ $0 <= 0 }) {
                self.active = nil
            }
            self.clearTask = nil
        }
    }
}

/// One row + its leading insertion gap. The row content is split into
/// top-half and bottom-half drop overlays so the entire row surface is
/// targetable: top half inserts above this row, bottom half inserts
/// below it. Adjacent rows' overlapping halves both target the same
/// insertion slot (via `BookmarkDragHover`), so the gap between them
/// stays open as the cursor crosses the boundary.
private struct ReorderableRowHost<Content: View>: View {
    let parentID: UUID?
    let index: Int
    let onDropInsert: (UUID, UUID?, Int) -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            InsertionGap(
                parentID: parentID,
                insertIndex: index,
                onDropInsert: onDropInsert
            )
            content()
                .background(
                    HalfDropTargets(
                        parentID: parentID,
                        topInsertIndex: index,
                        bottomInsertIndex: index + 1,
                        onDropInsert: onDropInsert
                    )
                )
        }
    }
}

private struct ReorderableTailGap: View {
    let parentID: UUID?
    let insertIndex: Int
    let onDropInsert: (UUID, UUID?, Int) -> Void

    var body: some View {
        InsertionGap(
            parentID: parentID,
            insertIndex: insertIndex,
            onDropInsert: onDropInsert
        )
    }
}

/// Visual gap that is also a drop target for its own slot. The drop
/// target matters: when the gap animates open it pushes the row below
/// it down, and the cursor — having activated the slot from the row's
/// top-half — ends up inside the freshly-opened gap. Without a target
/// here, the cursor would leave the row's hit zone, the slot would
/// clear, the gap would collapse, the row would jump back under the
/// cursor, and the whole thing would judder. Targeting the same slot
/// from the gap keeps refcount positive across the transition.
private struct InsertionGap: View {
    @Environment(BookmarkDragHover.self) private var hover

    let parentID: UUID?
    let insertIndex: Int
    let onDropInsert: (UUID, UUID?, Int) -> Void

    private var target: InsertionTarget {
        InsertionTarget(parentID: parentID, insertIndex: insertIndex)
    }

    private var active: Bool { hover.active == target }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                }
            }
            .frame(height: active ? 10 : 2)
            .contentShape(Rectangle())
            .dropDestination(for: BookmarkDragPayload.self) { items, _ in
                guard let payload = items.first else { return false }
                onDropInsert(payload.id, parentID, insertIndex)
                return true
            } isTargeted: { hovering in
                hover.setHovering(target, hovering)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: active)
    }
}

/// Two stacked invisible drop zones (top half + bottom half) that fill
/// the row's frame. Placed in the row's `.background` so foreground
/// controls (buttons, text fields) keep first crack at clicks while
/// drags fall through to these targets.
private struct HalfDropTargets: View {
    @Environment(BookmarkDragHover.self) private var hover

    let parentID: UUID?
    let topInsertIndex: Int
    let bottomInsertIndex: Int
    let onDropInsert: (UUID, UUID?, Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            half(insertIndex: topInsertIndex)
            half(insertIndex: bottomInsertIndex)
        }
    }

    private func half(insertIndex: Int) -> some View {
        let target = InsertionTarget(parentID: parentID, insertIndex: insertIndex)
        return Color.clear
            .contentShape(Rectangle())
            .dropDestination(for: BookmarkDragPayload.self) { items, _ in
                guard let payload = items.first else { return false }
                onDropInsert(payload.id, parentID, insertIndex)
                return true
            } isTargeted: { hovering in
                hover.setHovering(target, hovering)
            }
    }
}
