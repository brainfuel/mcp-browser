//
//  ContentView.swift
//  MCP Browser
//
//  Top-level view for one browser window. Owns a
//  `BrowserWindowViewModel`, lays out the bookmarks bar / tab bar /
//  WebViewHost, hangs the URL-suggestion overlay, and configures the
//  unified toolbar. All non-trivial state and behavior lives in the
//  view model; this file is only layout + binding.
//

import SwiftUI

struct ContentView: View {

    @State private var viewModel = BrowserWindowViewModel()
    @FocusState private var urlFieldFocused: Bool

    @Environment(MCPCoordinator.self) private var coordinator
    @Environment(BookmarkStore.self)  private var bookmarks
    @Environment(HistoryStore.self)   private var history
    @Environment(Recorder.self)       private var recorder
    @Environment(DownloadStore.self)  private var downloads
    @State private var showingDownloads: Bool = false

    var body: some View {
        @Bindable var vm = viewModel

        VStack(spacing: 0) {
            if vm.bookmarksBarVisible {
                BookmarksBarView()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if vm.hasMultipleTabs {
                VStack(spacing: 0) {
                    Divider()
                    TabBarStrip(
                        window: vm.window,
                        onSwitch: { vm.switchTab(id: $0) },
                        onClose:  { vm.closeTab(id: $0) }
                    )
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            AccessibilityWarningBar(summary: vm.browser?.accessibilitySummary)

            WebViewHost()
                .frame(minWidth: 800, minHeight: 520)
                .overlay(alignment: .topTrailing) {
                    if vm.findVisible {
                        FindBar(vm: vm)
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: vm.findVisible)
        }
        .animation(.easeInOut(duration: 0.18), value: vm.bookmarksBarVisible)
        .animation(.easeInOut(duration: 0.18), value: vm.hasMultipleTabs)
        .animation(.easeInOut(duration: 0.22), value: vm.browser?.accessibilitySummary?.score)
        .frame(minWidth: 960, minHeight: 600)
        .overlay(alignment: .top) {
            if !vm.suggestions.isEmpty {
                URLSuggestionList(
                    suggestions: vm.suggestions,
                    selection: vm.suggestionSelection,
                    onPick: {
                        vm.pickSuggestion($0)
                        urlFieldFocused = false
                    }
                )
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .environment(vm.window)
        .modifier(OptionalBrowserEnvironment(browser: vm.browser))
        .publishBrowserActions(vm.commandActions)
        .background(
            // Bridge NSWindow key/close events so MCP follows focus.
            WindowFocusObserver(
                onBecomeKey: { coordinator.setActive(vm.window) },
                onClose:     { coordinator.unregister(vm.window) }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            vm.setUp(
                coordinator: coordinator,
                bookmarks: bookmarks,
                history: history,
                recorder: recorder,
                downloads: downloads
            )
        }
        .onChange(of: vm.window.activeID) { _, _ in
            vm.syncURLFieldToActiveTab()
            urlFieldFocused = false
        }
        .onChange(of: vm.browser?.urlString ?? "") { _, new in
            if !urlFieldFocused { vm.urlField = new }
        }
        .onChange(of: vm.focusURLToken) { _, _ in
            urlFieldFocused = true
        }
        .toolbar {
            navigationGroup(vm: vm)
            urlBarItem(vm: vm)
            primaryActionsGroup(vm: vm)
        }
        .sheet(isPresented: $vm.showingSettings) {
            if let browser = vm.browser { SettingsView().environment(browser) }
        }
        .sheet(isPresented: $vm.showingBookmarks) {
            if let browser = vm.browser { BookmarksView().environment(browser) }
        }
        .sheet(isPresented: $vm.showingHistory) {
            if let browser = vm.browser { HistoryView().environment(browser) }
        }
    }

    // MARK: - Toolbar groups

    @ToolbarContentBuilder
    private func navigationGroup(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: vm.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!(vm.browser?.canGoBack ?? false))
            .help("Back")

            Button(action: vm.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!(vm.browser?.canGoForward ?? false))
            .help("Forward")

            Button {
                if vm.browser?.isLoading == true { vm.stop() } else { vm.reload() }
            } label: {
                Image(systemName: vm.browser?.isLoading == true ? "xmark" : "arrow.clockwise")
            }
            .help(vm.browser?.isLoading == true ? "Stop" : "Reload")
        }
    }

    @ToolbarContentBuilder
    private func urlBarItem(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            URLBarField(
                vm: vm,
                focused: $urlFieldFocused
            )
        }
    }

    @ToolbarContentBuilder
    private func primaryActionsGroup(vm: BrowserWindowViewModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: vm.newTab) {
                Image(systemName: "plus")
            }
            .help("New tab")

            Button { showingDownloads.toggle() } label: {
                Image(systemName: downloads.hasActiveDownloads
                      ? "arrow.down.circle.fill"
                      : "arrow.down.circle")
            }
            .help("Downloads")
            .popover(isPresented: $showingDownloads, arrowEdge: .top) {
                DownloadsPopover(store: downloads)
            }

            Button(action: vm.openBookmarks) {
                Image(systemName: "book")
            }
            .help("Bookmarks")

            Button(action: vm.openHistory) {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("History")

            Button(action: vm.openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
        }
    }
}

// MARK: - URL bar

/// The URL field plus the bookmark star and loading indicator that
/// share the principal toolbar slot. Pulled out so ContentView's
/// `body` reads as plain layout.
private struct URLBarField: View {
    @Bindable var vm: BrowserWindowViewModel
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 8)

            HStack(spacing: 6) {
                pageFavicon
                TextField("Search or enter address", text: $vm.urlField)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        vm.commitURLField()
                        focused = false
                    }
                    .onChange(of: vm.urlField) { _, _ in
                        vm.resetSuggestionSelection()
                    }
                    .onKeyPress(.downArrow) {
                        guard !vm.suggestions.isEmpty else { return .ignored }
                        vm.selectNextSuggestion()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !vm.suggestions.isEmpty else { return .ignored }
                        vm.selectPreviousSuggestion()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if focused { focused = false; return .handled }
                        return .ignored
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .frame(minWidth: 280, idealWidth: 560)

            Button(action: vm.toggleBookmark) {
                Image(systemName: vm.isCurrentBookmarked ? "star.fill" : "star")
                    .foregroundStyle(vm.isCurrentBookmarked ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
            .disabled(!vm.hasCurrentURL)
            .help(vm.isCurrentBookmarked ? "Remove bookmark" : "Bookmark this page")

            if vm.browser?.isLoading == true {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Favicon for the currently displayed page, draggable so the user
    /// can drop the page into a folder on the bookmarks bar (Safari-style).
    @ViewBuilder
    private var pageFavicon: some View {
        let urlString = vm.browser?.urlString ?? ""
        let title = vm.browser?.pageTitle ?? ""
        if urlString.isEmpty {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        } else {
            FaviconImage(urlString: urlString, size: 14)
                .draggable(PageDragPayload(title: title, url: urlString))
                .help("Drag to bookmark this page")
        }
    }
}

// MARK: - Accessibility warning bar

/// Slim banner shown beneath the chrome whenever the current page's
/// accessibility score is weak (amber) or poor (red). On `good` pages
/// — and when the user has switched the indicator off in Settings —
/// it stays hidden, taking no vertical space. Animates in/out so a
/// transition between sites doesn't feel abrupt.
private struct AccessibilityWarningBar: View {
    let summary: InspectPageTool.Summary?

    @AppStorage(BrowserTab.showAccessibilityIndicatorKey)
    private var showA11yIndicator: Bool = true

    var body: some View {
        // Show only when: setting is on, we have a summary, and the
        // score warrants a warning. Everything else collapses to nothing.
        if showA11yIndicator,
           let summary,
           summary.score == "weak" || summary.score == "poor" {
            HStack(spacing: 8) {
                Image(systemName: summary.score == "poor"
                      ? "exclamationmark.triangle.fill"
                      : "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)

                Text(message(for: summary))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(for: summary.score))
            .help(tooltip(for: summary))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func message(for summary: InspectPageTool.Summary) -> String {
        let prefix = summary.score == "poor"
            ? "Poor accessibility — AI agents will struggle to drive this page reliably"
            : "Weak accessibility — AI agents may need to fall back to vision"
        let detail = summary.reasons.first.map { " · \($0)" } ?? ""
        return prefix + detail
    }

    private func background(for score: String) -> some View {
        switch score {
        case "poor":
            return Color(nsColor: .systemRed).opacity(0.85)
        default: // "weak"
            return Color(nsColor: .systemOrange).opacity(0.85)
        }
    }

    private func tooltip(for summary: InspectPageTool.Summary) -> String {
        let label  = "Accessibility: \(summary.score.capitalized)"
        let detail = summary.reasons.joined(separator: "\n")
        let blurb  = "AI agents work better on pages with proper semantic markup. This score reflects how reliably an agent can drive this page."
        return [label, detail, blurb].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Tab strip

/// Safari-style horizontal tab strip: equal-width pills that share
/// the available width, with an elevated active tab and hairline
/// separators between adjacent inactive tabs. Pure presentation —
/// gets `BrowserWindow` for state and switch/close callbacks.
private struct TabBarStrip: View {
    let window: BrowserWindow
    let onSwitch: (UUID) -> Void
    let onClose:  (UUID) -> Void

    @State private var hoveredID: UUID? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(window.tabs.enumerated()), id: \.element.id) { index, tab in
                let isActive = tab.id == window.activeID
                let isHovered = tab.id == hoveredID
                let prevActive = index > 0 && window.tabs[index - 1].id == window.activeID
                let prevHovered = index > 0 && window.tabs[index - 1].id == hoveredID
                // Hide the leading separator when the tab on either
                // side is highlighted (active or hovered) — matches Safari.
                let showLeadingSeparator = index > 0 &&
                    !isActive && !isHovered && !prevActive && !prevHovered

                ZStack(alignment: .leading) {
                    if showLeadingSeparator {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 1, height: 16)
                    }
                    TabChip(
                        tab: tab,
                        isActive: isActive,
                        isHovered: isHovered,
                        canClose: window.tabs.count > 1,
                        onSwitch: { onSwitch(tab.id) },
                        onClose:  { onClose(tab.id) }
                    )
                    .onHover { inside in
                        hoveredID = inside ? tab.id : (hoveredID == tab.id ? nil : hoveredID)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 36)
        .background(.regularMaterial)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isActive: Bool
    let isHovered: Bool
    let canClose: Bool
    let onSwitch: () -> Void
    let onClose:  () -> Void

    var body: some View {
        let label = tab.pageTitle.isEmpty ? (tab.currentURL?.host ?? "New Tab") : tab.pageTitle
        let urlString = tab.currentURL?.absoluteString ?? ""

        Button(action: onSwitch) {
            HStack(spacing: 6) {
                // Favicon (placeholder when no URL yet)
                Group {
                    if urlString.isEmpty {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                    } else {
                        FaviconImage(urlString: urlString, size: 14)
                    }
                }
                .frame(width: 14, height: 14)

                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                // Close button: visible on hover or when active.
                if canClose && (isHovered || isActive) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .background(
                                Circle().fill(Color.secondary.opacity(0.001))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                } else {
                    // Reserve space so the title doesn't shift on hover.
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .background(chipBackground)
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private var chipBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 7)
                .fill(.thickMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.10), radius: 2, y: 1)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }
}

// MARK: - URL suggestion dropdown

private struct URLSuggestionList: View {
    let suggestions: [URLSuggestion]
    let selection: Int
    let onPick: (URLSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                row(suggestion, isSelected: index == selection)
                    .onTapGesture { onPick(suggestion) }
                if index < suggestions.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
    }

    private func row(_ s: URLSuggestion, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.source == .bookmark ? "star.fill" : "clock")
                .foregroundStyle(s.source == .bookmark ? Color.yellow : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title.isEmpty ? s.url : s.title).lineLimit(1)
                Text(s.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 4)
        )
    }
}

// MARK: - Find bar

private struct FindBar: View {
    @Bindable var vm: BrowserWindowViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find on page", text: $vm.findQuery)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($fieldFocused)
                .onSubmit { vm.findNext() }
                .onChange(of: vm.findQuery) { _, _ in
                    // Re-search as the user types so highlights track.
                    vm.findNext()
                }

            if vm.findHadNoMatches && !vm.findQuery.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button { vm.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(vm.findQuery.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button { vm.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(vm.findQuery.isEmpty)
            .help("Next match (⌘G)")

            Button { vm.closeFind() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 8, y: 2)
        .onAppear { fieldFocused = true }
        .onChange(of: vm.findFocusToken) { _, _ in fieldFocused = true }
    }
}

// MARK: - Environment plumbing

/// Injects the active tab's `BrowserTab` into the environment so child
/// views ( `BookmarksBarView`, sheets ) keep working with their existing
/// `@Environment(BrowserTab.self)` declarations. No-op when no tab
/// exists yet (window just opened).
private struct OptionalBrowserEnvironment: ViewModifier {
    let browser: BrowserTab?
    func body(content: Content) -> some View {
        if let browser {
            content.environment(browser)
        } else {
            content
        }
    }
}

#Preview {
    let agent = AgentSettings()
    let log = ActionLog()
    let rec = Recorder()
    let bm = BookmarkStore()
    return ContentView()
        .environment(MCPCoordinator(
            agentSettings: agent,
            actionLog: log,
            recorder: rec,
            presenter: DefaultBrowserPresenter(),
            bookmarks: bm
        ))
        .environment(bm)
        .environment(HistoryStore())
        .environment(agent)
        .environment(log)
        .environment(rec)
}
