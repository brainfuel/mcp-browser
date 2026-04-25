//
//  BrowserTabDelegate.swift
//  MCP Browser
//
//  Delegate the BrowserTab uses to talk back to its owner. Replaces
//  the previous handful of `var on*` mutable closures so missing wiring
//  is a compile-time error rather than a silent no-op, and so the model
//  is easier to reason about and mock.
//

import WebKit

/// Window-scoped owner of a tab. `BrowserWindow` is the production
/// conformer. Tests can stub this without touching WebKit internals.
@MainActor
protocol BrowserTabDelegate: AnyObject {

    /// A navigation completed. Owner typically records history.
    func browserTabDidFinishNavigation(
        _ model: BrowserTab,
        url: String,
        title: String
    )

    /// WebKit asks for a new web view (target=_blank, "Open Link in New
    /// Tab", `window.open`). Returning a fresh tab's web view tells
    /// WebKit to load the navigation into it; nil falls back to loading
    /// in the source tab.
    func browserTab(
        _ model: BrowserTab,
        didRequestNewTabWith configuration: WKWebViewConfiguration
    ) -> WKWebView?

    /// Current per-page agent state. Read on every navigation commit so
    /// toggling settings mid-session takes effect on the next load.
    func browserTabAgentState(for model: BrowserTab) -> BrowserAgentState

    /// True when the session-wide recorder is on. Pushed into the page
    /// so the recorder user script gates DOM event forwarding.
    func browserTabIsRecording(_ model: BrowserTab) -> Bool

    /// A user interaction was captured by the recorder user script.
    /// `tool` and `args` are the MCP tool call that would replay it.
    func browserTab(
        _ model: BrowserTab,
        didCaptureEvent tool: String,
        args: [String: Any]
    )
}

/// Snapshot of agent settings relevant to a single page load.
struct BrowserAgentState: Equatable {
    var sensitiveDomains: [String]
    var confirmEnabled: Bool

    static let disabled = BrowserAgentState(sensitiveDomains: [], confirmEnabled: false)
}
