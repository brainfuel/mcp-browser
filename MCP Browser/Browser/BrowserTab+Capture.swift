//
//  BrowserTab+Capture.swift
//  MCP Browser
//
//  Visual capture: PNG snapshot for the agent cursor / PiP / `screenshot`
//  tool, and PDF export for `pdf_export`.
//

import Foundation
import WebKit
import AppKit

extension BrowserTab {

    /// Full-viewport PNG snapshot of the current page state.
    func screenshotPNG() async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: config)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw BrowserError.snapshotFailed
        }
        return png
    }

    /// PNG snapshot cropped to the bounds of an element matched by
    /// `selector`. Scrolls the element into view first. Throws if the
    /// element can't be found or has zero size.
    func screenshotElementPNG(selector: String) async throws -> Data {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return null;
          el.scrollIntoView({block:'center', inline:'center'});
          const r = el.getBoundingClientRect();
          return {x: r.left, y: r.top, w: r.width, h: r.height};
        })()
        """
        guard
            let dict = try await runJS(js) as? [String: Any],
            let w = (dict["w"] as? NSNumber)?.doubleValue, w > 0,
            let h = (dict["h"] as? NSNumber)?.doubleValue, h > 0,
            let x = (dict["x"] as? NSNumber)?.doubleValue,
            let y = (dict["y"] as? NSNumber)?.doubleValue
        else {
            throw BrowserError.snapshotFailed
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.rect = CGRect(x: x, y: y, width: w, height: h)
        let image = try await webView.takeSnapshot(configuration: config)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw BrowserError.snapshotFailed
        }
        return png
    }

    /// Element-cropped PNG written to disk. Mirrors `screenshotPNG(filename:)`.
    func screenshotElementPNG(selector: String, filename: String? = nil) async throws -> URL {
        let data = try await screenshotElementPNG(selector: selector)
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let base = filename ?? (pageTitle.nonEmpty ?? "element") + ".png"
        let withExt = base.hasSuffix(".png") ? base : base + ".png"
        let dest = Self.uniqueDestination(in: downloads, preferred: withExt)
        try data.write(to: dest)
        let source = currentURL
        if let store = downloadStore {
            await MainActor.run { store.record(finishedFileAt: dest, sourceURL: source) }
        }
        return dest
    }

    /// Take a PNG snapshot and write it to disk. With `to` nil, falls
    /// back to a unique name inside `~/Downloads` (used by the
    /// `screenshot` MCP tool when a filename is supplied). Returns the
    /// destination URL.
    func screenshotPNG(filename: String? = nil, to destination: URL? = nil) async throws -> URL {
        let data = try await screenshotPNG()
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let base = filename ?? (pageTitle.nonEmpty ?? "page") + ".png"
            let withExt = base.hasSuffix(".png") ? base : base + ".png"
            dest = Self.uniqueDestination(in: downloads, preferred: withExt)
        }
        try data.write(to: dest)
        let source = currentURL
        if let store = downloadStore {
            await MainActor.run { store.record(finishedFileAt: dest, sourceURL: source) }
        }
        return dest
    }

    /// Render the current page to PDF and write it to disk. With `to`
    /// nil, falls back to a unique name inside `~/Downloads` (used by
    /// the `pdf_export` MCP tool). Returns the destination URL.
    func exportPDF(filename: String? = nil, to destination: URL? = nil) async throws -> URL {
        let data = try await renderPDF()
        let dest: URL
        if let destination {
            dest = destination
        } else {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let base = filename ?? (pageTitle.nonEmpty ?? "page") + ".pdf"
            let withExt = base.hasSuffix(".pdf") ? base : base + ".pdf"
            dest = Self.uniqueDestination(in: downloads, preferred: withExt)
        }
        try data.write(to: dest)
        return dest
    }

    /// Suggested filename for save panels, derived from the page title
    /// (or the URL host as a fallback).
    var suggestedPDFFilename: String {
        let stem = pageTitle.nonEmpty
            ?? currentURL?.host
            ?? "page"
        return stem
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            + ".pdf"
    }

    private func renderPDF() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            webView.createPDF { result in
                switch result {
                case .success(let d): cont.resume(returning: d)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
        }
    }
}
