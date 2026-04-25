//
//  AppCommands.swift
//  MCP Browser
//
//  Native macOS menu bar (File / Edit / View / History / Bookmarks /
//  Window / Help), modeled after Safari. Per-window state is published
//  by ContentView via `.focusedSceneValue` so each menu item operates
//  on whichever window is currently key.
//

import SwiftUI
import AppKit

// MARK: - Per-window action surface

/// Closures + flags published by the focused window's ContentView.
/// Menu items resolve them via `@FocusedValue`. When no window is
/// focused (e.g. all closed) every item is disabled.
struct BrowserCommandActions {
    var newTab: () -> Void
    var closeActiveTab: () -> Void
    var reopenLastClosedTab: () -> Void
    var reload: () -> Void
    var stop: () -> Void
    var goBack: () -> Void
    var goForward: () -> Void
    var toggleBookmarkCurrent: () -> Void
    var openBookmarks: () -> Void
    var openHistory: () -> Void
    var openSettings: () -> Void
    var savePagePDF: () -> Void
    var toggleBookmarksBar: () -> Void
    var focusURLBar: () -> Void
    /// 1-based tab index. Out-of-range numbers are silently ignored.
    var switchToTab: (Int) -> Void

    var canGoBack: Bool
    var canGoForward: Bool
    var isLoading: Bool
    var hasCurrentURL: Bool
    var isCurrentBookmarked: Bool
    var bookmarksBarVisible: Bool
    var canShowBookmarksBar: Bool
    var canReopenClosedTab: Bool
    var tabCount: Int
}

private struct BrowserCommandActionsKey: FocusedValueKey {
    typealias Value = BrowserCommandActions
}

extension FocusedValues {
    var browserActions: BrowserCommandActions? {
        get { self[BrowserCommandActionsKey.self] }
        set { self[BrowserCommandActionsKey.self] = newValue }
    }
}

extension View {
    /// Convenience wrapper around `.focusedSceneValue` for the per-window
    /// command actions. ContentView calls this to publish its menu hooks.
    func publishBrowserActions(_ actions: BrowserCommandActions) -> some View {
        focusedSceneValue(\.browserActions, actions)
    }
}

// MARK: - Commands

struct AppCommands: Commands {

    var body: some Commands {

        // MCP Browser › Settings…
        CommandGroup(replacing: .appSettings) {
            FocusedButton("Settings…", shortcut: ",") { $0.openSettings() }
        }

        // File › New Tab / Close Tab / Reopen Closed Tab / Save as PDF
        CommandGroup(after: .newItem) {
            FocusedButton("New Tab", shortcut: "t") { $0.newTab() }
            FocusedButton("Close Tab", shortcut: "w") { $0.closeActiveTab() }
            FocusedButton("Reopen Closed Tab",
                          shortcut: "t",
                          modifiers: [.command, .shift],
                          enabled: { $0.canReopenClosedTab }) { $0.reopenLastClosedTab() }
            Divider()
            FocusedButton("Save Page as PDF…",
                          shortcut: "p",
                          modifiers: [.command, .shift]) { $0.savePagePDF() }
        }

        // Edit › Open Location (⌘L) — focuses the URL bar.
        CommandGroup(after: .pasteboard) {
            Divider()
            FocusedButton("Open Location",
                          shortcut: "l") { $0.focusURLBar() }
        }

        // Window › Tab N (⌘1…⌘9). Hidden when the window has only one
        // tab to keep the menu uncluttered.
        CommandGroup(before: .windowList) {
            FocusedTabSwitchers()
            Divider()
        }

        // View › Reload / Stop / Bookmarks Bar
        // Inject into the existing View menu (which SwiftUI auto-adds
        // for the toolbar item) instead of creating a duplicate.
        CommandGroup(after: .toolbar) {
            Divider()
            FocusedButton("Reload", shortcut: "r") { $0.reload() }
            FocusedButton("Stop",
                          shortcut: ".",
                          enabled: { $0.isLoading }) { $0.stop() }
            Divider()
            FocusedBookmarksBarToggle()
        }

        // History › Back / Forward / Show All
        CommandMenu("History") {
            FocusedButton("Back",
                          shortcut: "[",
                          enabled: { $0.canGoBack }) { $0.goBack() }
            FocusedButton("Forward",
                          shortcut: "]",
                          enabled: { $0.canGoForward }) { $0.goForward() }
            Divider()
            FocusedButton("Show All History",
                          shortcut: "y") { $0.openHistory() }
        }

        // Bookmarks › Add / Show
        CommandMenu("Bookmarks") {
            FocusedBookmarkToggle()
            Divider()
            FocusedButton("Show All Bookmarks") { $0.openBookmarks() }
        }

        // Help › leave the SwiftUI default in place.
    }
}

// MARK: - Helper views

/// Menu button that pulls the focused window's actions out of the
/// environment, runs `action(actions)`, and disables itself when no
/// window is focused or `enabled` returns false.
private struct FocusedButton: View {
    @FocusedValue(\.browserActions) private var actions

    let title: String
    let shortcut: KeyEquivalent?
    let modifiers: EventModifiers
    let enabled: (BrowserCommandActions) -> Bool
    let action: (BrowserCommandActions) -> Void

    init(_ title: String,
         shortcut: KeyEquivalent? = nil,
         modifiers: EventModifiers = .command,
         enabled: @escaping (BrowserCommandActions) -> Bool = { _ in true },
         action: @escaping (BrowserCommandActions) -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.modifiers = modifiers
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        let isEnabled = actions.map(enabled) ?? false
        Group {
            if let shortcut {
                Button(title) { actions.map(action) }
                    .keyboardShortcut(shortcut, modifiers: modifiers)
            } else {
                Button(title) { actions.map(action) }
            }
        }
        .disabled(!isEnabled)
    }
}

/// "Add Bookmark…" / "Remove Bookmark" toggle item — title flips with
/// the bookmark state of the focused window's current page.
private struct FocusedBookmarkToggle: View {
    @FocusedValue(\.browserActions) private var actions

    var body: some View {
        let isOn = actions?.isCurrentBookmarked ?? false
        let title = isOn ? "Remove Bookmark" : "Add Bookmark…"
        Button(title) { actions?.toggleBookmarkCurrent() }
            .keyboardShortcut("d")
            .disabled(actions?.hasCurrentURL != true)
    }
}

/// ⌘1–⌘9 tab switchers. Each is a separate menu item so SwiftUI binds
/// the correct keyboard shortcut to the correct action; building them in
/// a ForEach inside `Commands` doesn't bind shortcuts reliably.
private struct FocusedTabSwitchers: View {
    @FocusedValue(\.browserActions) private var actions

    var body: some View {
        let count = actions?.tabCount ?? 0
        Group {
            tabButton(1, key: "1", visible: count >= 1)
            tabButton(2, key: "2", visible: count >= 2)
            tabButton(3, key: "3", visible: count >= 3)
            tabButton(4, key: "4", visible: count >= 4)
            tabButton(5, key: "5", visible: count >= 5)
            tabButton(6, key: "6", visible: count >= 6)
            tabButton(7, key: "7", visible: count >= 7)
            tabButton(8, key: "8", visible: count >= 8)
            tabButton(9, key: "9", visible: count >= 9)
        }
    }

    @ViewBuilder
    private func tabButton(_ n: Int, key: Character, visible: Bool) -> some View {
        if visible {
            Button("Tab \(n)") { actions?.switchToTab(n) }
                .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        }
    }
}

/// "Show/Hide Bookmarks Bar" — title flips with the current visibility.
/// Disabled when the user has no bookmarks pinned to the bar (the bar
/// always hides itself in that case).
private struct FocusedBookmarksBarToggle: View {
    @FocusedValue(\.browserActions) private var actions

    var body: some View {
        let visible = actions?.bookmarksBarVisible ?? false
        let title = visible ? "Hide Bookmarks Bar" : "Show Bookmarks Bar"
        Button(title) { actions?.toggleBookmarksBar() }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(actions?.canShowBookmarksBar != true)
    }
}
