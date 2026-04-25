//
//  WebViewHost.swift
//  MCP Browser
//
//  Swaps the active tab's WKWebView into the SwiftUI view tree. The
//  window owns a BrowserWindow; each tab has its own persistent
//  WKWebView so switching tabs is as cheap as re-parenting.
//

import SwiftUI
import WebKit

struct WebViewHost: NSViewRepresentable {
    @Environment(BrowserWindow.self) private var tabs

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        attach(tabs.active?.webView, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        attach(tabs.active?.webView, to: container)
    }

    private func attach(_ webView: WKWebView?, to container: NSView) {
        let current = container.subviews.first as? WKWebView
        if current === webView { return }
        current?.removeFromSuperview()
        guard let webView else { return }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
