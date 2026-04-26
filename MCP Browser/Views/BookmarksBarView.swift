//
//  BookmarksBarView.swift
//  MCP Browser
//
//  Safari-style strip of the bar folder's direct children. Bookmarks
//  render as buttons that navigate; sub-folders render as
//  click-to-open menus that recurse for deeper nesting.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Lightweight payload for dragging bookmarks/folders around the bar
/// and the management sheet. The id is enough — the store is the
/// source of truth for everything else.
struct BookmarkDragPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// Drag payload for the favicon in the URL bar — represents the
/// currently-displayed page so it can be dropped onto a folder to
/// create a new bookmark inside it.
struct PageDragPayload: Codable, Transferable {
    let title: String
    let url: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct BookmarksBarView: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser

    @State private var isBarTargeted = false

    var body: some View {
        let nodes = store.barChildren

        Group {
            if nodes.isEmpty {
                HStack {
                    Text("Drag a page here to bookmark it")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            } else {
                BarOverflowLayout(spacing: 4) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        BookmarksBarNodeView(node: node, index: index)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                    BarOverflowMenu(allNodes: nodes)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: nodeIDs(nodes))
            }
        }
        .background(
            (isBarTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                .animation(.easeOut(duration: 0.12), value: isBarTargeted)
        )
        .background(.regularMaterial)
        .frame(height: nodes.isEmpty ? 28 : nil)
        .dropDestination(for: PageDragPayload.self) { items, _ in
            guard let page = items.first, !page.url.isEmpty else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.add(title: page.title, url: page.url, parentID: store.barFolderID)
            }
            return true
        } isTargeted: { isBarTargeted = $0 }
        .dropDestination(for: BookmarkDragPayload.self) { items, _ in
            guard let payload = items.first else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.move(id: payload.id, to: store.barFolderID)
            }
            return true
        } isTargeted: { isBarTargeted = $0 }
    }

    private func nodeIDs(_ nodes: [BookmarkNode]) -> [UUID] {
        nodes.map(\.id)
    }
}

// MARK: - Overflow layout & menu

/// Lays its subviews out left-to-right, fitting as many as the proposed
/// width allows. The LAST subview is treated as the overflow indicator
/// — it's only placed when one or more leading subviews don't fit, and
/// when placed it takes the trailing slot (Safari-style chevron).
private struct BarOverflowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (_, used, h) = compute(subviews: subviews, width: width)
        return CGSize(width: min(used, width), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count > 0 else { return }
        let items = subviews.dropLast()
        let overflow = subviews[subviews.count - 1]
        // Compute against actual bounds — `sizeThatFits` may have been
        // called with `.infinity` proposals which can't drive placement.
        let (computedVisible, _, _) = compute(subviews: subviews, width: bounds.width)
        let visible = min(computedVisible, items.count)
        let hiddenCount = items.count - visible
        var x = bounds.minX

        for i in 0..<visible {
            let s = items[i].sizeThatFits(.unspecified)
            items[i].place(
                at: CGPoint(x: x, y: bounds.midY - s.height / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(s)
            )
            x += s.width + spacing
        }

        // Park unplaced items offscreen — SwiftUI requires every subview
        // to be placed, otherwise it lands at the origin and clusters
        // visibly on top of the visible items.
        for i in visible..<items.count {
            items[i].place(
                at: CGPoint(x: -10_000, y: -10_000),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 0, height: 0)
            )
        }

        if hiddenCount > 0 {
            let s = overflow.sizeThatFits(.unspecified)
            overflow.place(
                at: CGPoint(x: x, y: bounds.midY - s.height / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(s)
            )
        } else {
            // Park offscreen so the menu is in the tree but invisible.
            overflow.place(
                at: CGPoint(x: -10_000, y: -10_000),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 0, height: 0)
            )
        }
    }

    /// Returns (visible count, used width, height). Reserves room for
    /// the overflow chevron unconditionally so its appearance/disappearance
    /// can't change the visible count and trigger layout oscillation.
    private func compute(subviews: Subviews, width: CGFloat) -> (Int, CGFloat, CGFloat) {
        guard subviews.count > 0 else { return (0, 0, 0) }
        let items = subviews.dropLast()
        let overflow = subviews[subviews.count - 1]
        let overflowSize = overflow.sizeThatFits(.unspecified)

        var maxHeight: CGFloat = 0
        let budget = width - overflowSize.width - (items.isEmpty ? 0 : spacing)
        var used: CGFloat = 0
        var visible = 0
        for (i, sub) in items.enumerated() {
            let s = sub.sizeThatFits(.unspecified)
            maxHeight = max(maxHeight, s.height)
            let inc = (i == 0 ? 0 : spacing) + s.width
            if used + inc > budget { break }
            used += inc
            visible = i + 1
        }
        let total = used + (visible > 0 ? spacing : 0) + overflowSize.width
        return (visible, total, max(maxHeight, overflowSize.height))
    }
}

/// Trailing chevron menu that lists every bookmark/folder that didn't
/// fit on the bar. Folders surface as cascading submenus, matching the
/// existing folder-chip dropdown.
private struct BarOverflowMenu: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser

    let allNodes: [BookmarkNode]

    var body: some View {
        // SwiftUI's Menu flashes here and logs AppKit item-view
        // mismatches while the overflow contents are being presented.
        // Drive the chevron with a tiny AppKit control instead so the
        // icon's rendering stays stable while AppKit owns the menu
        // lifecycle end-to-end.
        BarOverflowMenuButton(allNodes: allNodes, store: store, browser: browser)
            .frame(width: 24, height: 22)
    }
}

@MainActor
private struct BarOverflowMenuButton: NSViewRepresentable {
    let allNodes: [BookmarkNode]
    let store: BookmarkStore
    let browser: BrowserTab

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, browser: browser)
    }

    func makeNSView(context: Context) -> OverflowChevronControl {
        let control = OverflowChevronControl()
        control.onClick = { [weak coordinator = context.coordinator] sender in
            coordinator?.showMenu(from: sender)
        }
        context.coordinator.control = control
        context.coordinator.updateMenu(allNodes: allNodes)
        control.toolTip = "All bookmarks"
        return control
    }

    func updateNSView(_ control: OverflowChevronControl, context: Context) {
        context.coordinator.store = store
        context.coordinator.browser = browser
        context.coordinator.control = control
        context.coordinator.updateMenu(allNodes: allNodes)
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        weak var control: OverflowChevronControl?
        var store: BookmarkStore
        var browser: BrowserTab
        private var lastNodes: [BookmarkNode] = []
        private var pendingNodes: [BookmarkNode]?
        private var isMenuOpen = false
        private var currentMenu: NSMenu?

        init(store: BookmarkStore, browser: BrowserTab) {
            self.store = store
            self.browser = browser
        }

        func updateMenu(allNodes: [BookmarkNode]) {
            guard allNodes != lastNodes || currentMenu == nil else { return }
            guard !isMenuOpen else {
                pendingNodes = allNodes
                return
            }

            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            for node in allNodes {
                menu.addItem(makeItem(for: node))
            }
            currentMenu = menu
            lastNodes = allNodes
        }

        private func makeItem(for node: BookmarkNode) -> NSMenuItem {
            switch node {
            case .bookmark(let bookmark):
                let item = NSMenuItem(
                    title: displayTitle(for: bookmark),
                    action: #selector(openBookmark(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.image = NSImage(
                    systemSymbolName: "globe",
                    accessibilityDescription: nil
                )
                item.representedObject = bookmark.url
                return item

            case .folder(let folder):
                let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: folder.name)
                submenu.autoenablesItems = false
                let children = store.children(of: folder.id)
                if children.isEmpty {
                    let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
                    empty.isEnabled = false
                    submenu.addItem(empty)
                } else {
                    for child in children {
                        submenu.addItem(makeItem(for: child))
                    }
                }
                item.submenu = submenu
                return item
            }
        }

        @objc private func openBookmark(_ sender: NSMenuItem) {
            guard let url = sender.representedObject as? String else { return }
            browser.navigate(to: url)
        }

        func showMenu(from sender: OverflowChevronControl) {
            guard let menu = currentMenu, menu.items.isEmpty == false else { return }
            let point = NSPoint(x: 0, y: sender.bounds.maxY + 2)
            menu.popUp(positioning: nil, at: point, in: sender)
        }

        func menuWillOpen(_ menu: NSMenu) {
            isMenuOpen = true
        }

        func menuDidClose(_ menu: NSMenu) {
            isMenuOpen = false
            if let pendingNodes {
                self.pendingNodes = nil
                updateMenu(allNodes: pendingNodes)
            }
        }

        private func displayTitle(for bookmark: Bookmark) -> String {
            let trimmed = bookmark.title.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            return URL(string: bookmark.url)?.host ?? bookmark.url
        }
    }
}

private final class OverflowChevronControl: NSView {
    var onClick: ((OverflowChevronControl) -> Void)?
    private let imageView = NSImageView()
    private var tracking: NSTrackingArea?
    private var isHovering = false {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(
            systemSymbolName: "chevron.right.2",
            accessibilityDescription: "More bookmarks"
        )
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .secondaryLabelColor
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 24, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func updateAppearance() {
        layer?.backgroundColor = isHovering
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
    }
}

// MARK: - Single node (item or folder)

/// Routes a `BookmarkNode` to the correct chip view.
private struct BookmarksBarNodeView: View {
    let node: BookmarkNode
    let index: Int

    var body: some View {
        switch node {
        case .bookmark(let bookmark):
            BookmarkBarItem(bookmark: bookmark, index: index)
        case .folder(let folder):
            BookmarkBarFolder(folder: folder, index: index)
        }
    }
}

// MARK: - Bookmark chip

private struct BookmarkBarItem: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser
    @Environment(BrowserWindow.self) private var window

    let bookmark: Bookmark
    let index: Int
    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        Button {
            browser.navigate(to: bookmark.url)
        } label: {
            HStack(spacing: 5) {
                FaviconImage(urlString: bookmark.url, size: 14)
                Text(displayTitle)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(bookmark.title)\n\(bookmark.url)")
        .contextMenu {
            Button("Open in New Tab") {
                window.newTab(url: bookmark.url)
            }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url, forType: .string)
            }
            Divider()
            Button("Remove", role: .destructive) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    store.remove(id: bookmark.id)
                }
            }
        }
        .draggable(BookmarkDragPayload(id: bookmark.id))
        .dropDestination(for: BookmarkDragPayload.self) { items, _ in
            guard let payload = items.first, payload.id != bookmark.id else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.move(id: payload.id, to: store.barFolderID, index: index)
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: PageDragPayload.self) { items, _ in
            guard let page = items.first, !page.url.isEmpty else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                if let newID = store.add(title: page.title, url: page.url, parentID: store.barFolderID) {
                    store.move(id: newID, to: store.barFolderID, index: index)
                }
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var displayTitle: String {
        let trimmed = bookmark.title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return URL(string: bookmark.url)?.host ?? bookmark.url
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fillColor)
    }

    private var fillColor: Color {
        if isTargeted { return Color.accentColor.opacity(0.25) }
        if isHovering { return Color.secondary.opacity(0.15) }
        return .clear
    }
}

// MARK: - Folder chip

/// Click-to-open dropdown of a folder's contents. Subfolders surface
/// as cascading submenus via SwiftUI's native `Menu` nesting.
private struct BookmarkBarFolder: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser

    let folder: BookmarkFolder
    let index: Int
    @State private var isTargeted = false
    @Environment(BrowserWindow.self) private var window

    private func openAll(in folderID: UUID) {
        for node in store.children(of: folderID) {
            if case .bookmark(let b) = node {
                window.newTab(url: b.url)
            }
        }
    }

    private let iconTextSpacing: CGFloat = 2

    var body: some View {
        HStack(spacing: iconTextSpacing) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .draggable(BookmarkDragPayload(id: folder.id))
                .help("Drag to move folder")

            Menu {
                BookmarkFolderMenuContents(folderID: folder.id)
            } label: {
                Text(folder.name)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.leading, -1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .help(folder.name)
        .contextMenu {
            Button("Open All in New Tabs") {
                openAll(in: folder.id)
            }
            Divider()
            Button("Remove", role: .destructive) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    store.remove(id: folder.id)
                }
            }
        }
        .dropDestination(for: BookmarkDragPayload.self) { items, _ in
            guard let payload = items.first, payload.id != folder.id else { return false }
            // Folder-onto-folder reorders along the bar; bookmark-onto-folder
            // drops the bookmark inside the folder. To nest folders, use the
            // bookmarks management sheet.
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                if store.folder(id: payload.id) != nil {
                    store.move(id: payload.id, to: store.barFolderID, index: index)
                } else {
                    store.move(id: payload.id, to: folder.id)
                }
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: PageDragPayload.self) { items, _ in
            guard let page = items.first, !page.url.isEmpty else { return false }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                store.add(title: page.title, url: page.url, parentID: folder.id)
            }
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

/// Recursive menu body: bookmarks become buttons, subfolders become
/// nested `Menu`s. Pulled into its own view so the recursion is named
/// and the type-checker doesn't have to chew on a deep closure.
private struct BookmarkFolderMenuContents: View {
    @Environment(BookmarkStore.self) private var store
    @Environment(BrowserTab.self) private var browser

    let folderID: UUID

    var body: some View {
        let children = store.children(of: folderID)
        if children.isEmpty {
            Text("Empty").italic()
        } else {
            ForEach(children) { node in
                switch node {
                case .bookmark(let bookmark):
                    Button {
                        browser.navigate(to: bookmark.url)
                    } label: {
                        Label(displayTitle(for: bookmark), systemImage: "globe")
                    }
                case .folder(let sub):
                    Menu(sub.name) {
                        BookmarkFolderMenuContents(folderID: sub.id)
                    }
                }
            }
            // "Open All in New Tabs" would be a nice add here later.
        }
    }

    private func displayTitle(for bookmark: Bookmark) -> String {
        let t = bookmark.title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        return URL(string: bookmark.url)?.host ?? bookmark.url
    }
}
