//
//  BookmarkImporter.swift
//  MCP Browser
//
//  Parses the Netscape HTML bookmarks format used by Safari, Chrome,
//  Firefox, Edge, and most other browsers when you "Export Bookmarks".
//  Folder hierarchy is preserved: each <H3> introduces a folder whose
//  contents are the following <DL>'s anchors, and the folder marked
//  as the personal-toolbar (Safari "Favourites", Chrome "Bookmarks
//  bar") is adopted as the app's bookmarks-bar root.
//

import Foundation

enum BookmarkImporter {
    struct Result {
        var added: Int
        var skipped: Int
    }

    enum ImportError: LocalizedError {
        case unzipFailed(String)
        case noBookmarksHTMLInArchive

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let why):
                return "Couldn't extract the .zip: \(why)"
            case .noBookmarksHTMLInArchive:
                return "The .zip didn't contain a Bookmarks.html file. If you exported from Safari, make sure 'Bookmarks' was selected in the export sheet."
            }
        }
    }

    /// Top-level entry. Accepts either a Netscape HTML bookmarks file
    /// or a zip archive (e.g. Safari's "Export Browsing Data to File")
    /// containing one. Extracts as needed and parses.
    @MainActor
    static func `import`(from url: URL, into store: BookmarkStore) throws -> Result {
        if url.pathExtension.lowercased() == "zip" {
            let html = try extractBookmarksHTML(fromZip: url)
            return try importHTML(from: html, into: store)
        }
        return try importHTML(from: url, into: store)
    }

    /// Extract `<archive>/.../Bookmarks.html` from a zip into a temp
    /// directory and return its URL. Uses `/usr/bin/ditto` because
    /// it's available on every macOS install and works inside the
    /// app sandbox without extra entitlements.
    private static func extractBookmarksHTML(fromZip zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent(
            "bookmark-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, dest.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ImportError.unzipFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown"
            throw ImportError.unzipFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let html = findBookmarksHTML(under: dest) {
            return html
        }
        throw ImportError.noBookmarksHTMLInArchive
    }

    /// Walk the extracted directory and return the first .html file
    /// whose name suggests it's the bookmarks export. Safari names it
    /// `Bookmarks.html`; Chrome's older zip naming used the same.
    private static func findBookmarksHTML(under root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else {
            return nil
        }
        var fallback: URL?
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "html" else { continue }
            let name = url.lastPathComponent.lowercased()
            if name.contains("bookmark") { return url }
            fallback = fallback ?? url
        }
        return fallback
    }

    /// Read `url` and insert any new bookmarks into `store`. Existing
    /// entries (matched by URL) are skipped. Anchors that live inside
    /// a `<H3 PERSONAL_TOOLBAR_FOLDER="true">` folder (Safari's
    /// "Favorites", Chrome's "Bookmarks bar") are auto-pinned to the
    /// app's bookmarks bar so the toolbar set carries over.
    @MainActor
    static func importHTML(from url: URL, into store: BookmarkStore) throws -> Result {
        let text = try String(contentsOf: url, encoding: .utf8)
        let tokens = tokenize(text)

        var added = 0
        var skipped = 0

        // The H3 directly preceding a <DL> describes that DL's folder.
        // We hold it here until the <DL> opens, then create the folder
        // and push it onto the stack.
        var pending: (name: String, isPersonalToolbar: Bool)? = nil

        // One entry per currently-open <DL>. `id` is nil for the
        // outermost <DL> that wraps the document root (no preceding H3),
        // in which case anchors land at the app root or at the nearest
        // ancestor folder.
        var folderStack: [UUID?] = []

        for token in tokens {
            switch token {
            case .h3(let isPersonalToolbar, let name):
                pending = (name: name, isPersonalToolbar: isPersonalToolbar)
            case .dlOpen:
                if let p = pending {
                    let parentID = currentFolderID(folderStack)
                    let newID = store.createFolder(name: p.name, parentID: parentID)
                    if p.isPersonalToolbar {
                        store.setBarFolder(id: newID)
                    }
                    folderStack.append(newID)
                    pending = nil
                } else {
                    folderStack.append(nil)
                }
            case .dlClose:
                _ = folderStack.popLast()
            case .anchor(let href, let title):
                let trimmedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedHref.isEmpty, trimmedHref.hasPrefix("http") else {
                    skipped += 1
                    continue
                }
                if store.isBookmarked(url: trimmedHref) {
                    skipped += 1
                    continue
                }
                let display = title.isEmpty ? trimmedHref : title
                let parentID = currentFolderID(folderStack)
                if store.add(title: display, url: trimmedHref, parentID: parentID) != nil {
                    added += 1
                }
            }
        }
        return Result(added: added, skipped: skipped)
    }

    /// Innermost open folder id in the stack, or nil when we're at the
    /// document root (or only DL wrappers without an H3 are open).
    private static func currentFolderID(_ stack: [UUID?]) -> UUID? {
        for entry in stack.reversed() {
            if let id = entry { return id }
        }
        return nil
    }

    // MARK: - Tokenizer

    /// One meaningful piece of the bookmarks document, in source order.
    private enum Token {
        case h3(personalToolbar: Bool, name: String)
        case dlOpen
        case dlClose
        case anchor(href: String, title: String)
    }

    /// Folder names that mean "this folder is the bookmarks bar" in
    /// the major browsers' exports. Matched case-insensitively because
    /// Safari now drops the `PERSONAL_TOOLBAR_FOLDER` attribute and
    /// just relies on the name.
    private static let toolbarFolderNames: Set<String> = [
        "favorites", "favourites",
        "bookmarks bar", "bookmarks toolbar",
        "favorites bar", "favourites bar"
    ]

    /// Find every H3, <DL>, </DL>, and <A> in the document and return
    /// them in document order so callers can walk the structure as a
    /// stream rather than nesting parsers.
    private static func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var found: [(Int, Token)] = []

        // Capture both the attribute string and the folder name so we
        // can decide via either signal: explicit PERSONAL_TOOLBAR_FOLDER
        // (older browsers) or a known name (Safari, Chrome, Firefox).
        let h3Re = try? NSRegularExpression(
            pattern: #"<H3([^>]*)>([\s\S]*?)</H3>"#,
            options: [.caseInsensitive]
        )
        h3Re?.enumerateMatches(in: text, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let attrs = ns.substring(with: m.range(at: 1))
            let displayName = decodeEntities(ns.substring(with: m.range(at: 2)))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let attributeFlag = attrs.range(
                of: #"PERSONAL_TOOLBAR_FOLDER\s*=\s*"true""#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            let nameFlag = toolbarFolderNames.contains(displayName.lowercased())
            found.append((m.range.location,
                          .h3(personalToolbar: attributeFlag || nameFlag,
                              name: displayName.isEmpty ? "Folder" : displayName)))
        }

        let dlOpenRe = try? NSRegularExpression(
            pattern: #"<DL[^>]*>"#,
            options: [.caseInsensitive]
        )
        dlOpenRe?.enumerateMatches(in: text, range: fullRange) { m, _, _ in
            if let m { found.append((m.range.location, .dlOpen)) }
        }

        let dlCloseRe = try? NSRegularExpression(
            pattern: #"</DL>"#,
            options: [.caseInsensitive]
        )
        dlCloseRe?.enumerateMatches(in: text, range: fullRange) { m, _, _ in
            if let m { found.append((m.range.location, .dlClose)) }
        }

        let anchorRe = try? NSRegularExpression(
            pattern: #"<A\s+[^>]*HREF\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)</A>"#,
            options: [.caseInsensitive]
        )
        anchorRe?.enumerateMatches(in: text, range: fullRange) { m, _, _ in
            guard let m, m.numberOfRanges >= 3 else { return }
            let href = ns.substring(with: m.range(at: 1))
            let title = decodeEntities(ns.substring(with: m.range(at: 2)))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            found.append((m.range.location, .anchor(href: href, title: title)))
        }

        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Decode the small set of HTML entities Netscape exporters use.
    /// We keep the list short on purpose — anything we miss survives
    /// as the literal entity, which renders fine in our UI.
    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;",  with: "'")
    }
}
