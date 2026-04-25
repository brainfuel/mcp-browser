//
//  ContextWebView.swift
//  MCP Browser
//
//  WKWebView subclass that rewrites the right-click menu so the
//  default "Open Link in New Window" reads "Open Link in New Tab".
//  The routing itself happens in BrowserTab's createWebViewWith —
//  WebKit fires that for both menu choices, and our UIDelegate
//  returns a fresh tab's web view.
//

import WebKit

final class ContextWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            // Identifiers are stable across WebKit releases; titles are
            // localized, so keying on the identifier is the robust path.
            guard let id = item.identifier?.rawValue else { continue }
            if id == "WKMenuItemIdentifierOpenLinkInNewWindow" {
                item.title = "Open Link in New Tab"
            }
        }
    }
}
