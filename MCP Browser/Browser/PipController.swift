//
//  PipController.swift
//  MCP Browser
//
//  Floating always-on-top mini-window that shows a thumbnail of the
//  active MCP tab. Updated after each MCP tool call so you can glance
//  at what the agent is doing from another app.
//
//  Implementation: a non-activating NSPanel at `.floating` level with
//  an NSImageView as its content. AgentSettings owns the on/off state;
//  MCPCoordinator wires its toggle to `refresh()`.
//

import AppKit
import Observation

@MainActor
final class PipController: NSObject, NSWindowDelegate {
    private weak var settings: AgentSettings?
    private var panel: NSPanel?
    private var imageView: NSImageView?

    init(settings: AgentSettings) {
        self.settings = settings
        super.init()
        refresh()
    }

    /// Open or close the panel based on the current settings value.
    func refresh() {
        if settings?.pipEnabled == true {
            openPanel()
        } else {
            closePanel()
        }
    }

    /// Replace the thumbnail. Called from MCPToolRegistry after each
    /// tool call when the feature is on. Cheap — the image view just
    /// redraws with the new NSImage.
    func updateFrame(pngData: Data) {
        guard let image = NSImage(data: pngData) else { return }
        imageView?.image = image
    }

    // MARK: - Panel lifecycle

    private func openPanel() {
        if panel != nil { return }

        let size = NSSize(width: 360, height: 225)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        // Bottom-right corner, with a little inset.
        let origin = NSPoint(
            x: screenFrame.maxX - size.width - 24,
            y: screenFrame.minY + 24
        )

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Agent view"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.delegate = self

        let iv = NSImageView(frame: NSRect(origin: .zero, size: size))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        p.contentView = iv

        panel = p
        imageView = iv
        p.orderFrontRegardless()
    }

    private func closePanel() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        imageView = nil
    }

    // MARK: - NSWindowDelegate

    /// If the user clicks the close button, reflect that back into the
    /// settings so the toggle in the Agent tab stays in sync.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.settings?.pipEnabled = false
        }
    }
}
