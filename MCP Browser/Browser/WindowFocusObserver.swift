//
//  WindowFocusObserver.swift
//  MCP Browser
//
//  Tiny NSViewRepresentable that bridges its host NSWindow's
//  becomeKey / willClose events up to SwiftUI. Used so each
//  ContentView can report "I'm focused now" to the MCPCoordinator.
//

import SwiftUI
import AppKit

struct WindowFocusObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // The view isn't in a window until after makeNSView returns,
        // so defer attachment. updateNSView also re-checks in case the
        // view moves windows.
        DispatchQueue.main.async {
            context.coordinator.attach(to: v.window, onKey: onBecomeKey, onClose: onClose)
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            if context.coordinator.window !== v.window {
                context.coordinator.attach(to: v.window, onKey: onBecomeKey, onClose: onClose)
            }
        }
    }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var window: NSWindow?
        private var keyToken: NSObjectProtocol?
        private var closeToken: NSObjectProtocol?

        func attach(to window: NSWindow?, onKey: @escaping () -> Void, onClose: @escaping () -> Void) {
            detach()
            self.window = window
            guard let window else { return }
            let nc = NotificationCenter.default
            keyToken = nc.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                      object: window, queue: .main) { _ in onKey() }
            closeToken = nc.addObserver(forName: NSWindow.willCloseNotification,
                                        object: window, queue: .main) { _ in onClose() }
            // If we attach to a window that's already key (common for
            // the first window), fire the callback once immediately.
            if window.isKeyWindow { onKey() }
        }

        func detach() {
            let nc = NotificationCenter.default
            if let keyToken { nc.removeObserver(keyToken) }
            if let closeToken { nc.removeObserver(closeToken) }
            keyToken = nil
            closeToken = nil
            window = nil
        }

        deinit { detach() }
    }
}
