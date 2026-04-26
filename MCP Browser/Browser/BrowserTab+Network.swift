//
//  BrowserTab+Network.swift
//  MCP Browser
//
//  HTTP-flavored MCP tools: download a URL to disk, find every match
//  for a query in the page, and read the in-page network log shim
//  installed by `BrowserScripts.networkLog`.
//

import Foundation
import WebKit

extension BrowserTab {

    // MARK: - Download

    /// Download `url` to `~/Downloads`. Filename comes from `filename`
    /// override → `Content-Disposition` suggested filename → URL last
    /// path component → `"download"`. Collisions get a `-N` suffix.
    func download(url: URL, filename: String? = nil) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let baseName = filename
            ?? response.suggestedFilename
            ?? url.lastPathComponent.nonEmpty
            ?? "download"
        let dest = Self.uniqueDestination(in: downloads, preferred: baseName)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    // MARK: - Find in page

    /// Find every occurrence of `query` and return its bounding rect +
    /// surrounding context. Capped at `limit` to keep responses bounded.
    func findInPage(query: String, caseSensitive: Bool, limit: Int) async throws -> Any? {
        let js = """
        (function(q, cs, limit){
          if (!q) return [];
          const results = [];
          const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode: n => (n.parentElement && getComputedStyle(n.parentElement).visibility !== 'hidden')
              ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
          });
          const needle = cs ? q : q.toLowerCase();
          let node;
          while ((node = walker.nextNode())) {
            const text = node.nodeValue;
            const hay = cs ? text : text.toLowerCase();
            let i = 0;
            while ((i = hay.indexOf(needle, i)) !== -1) {
              if (results.length >= limit) return results;
              const range = document.createRange();
              range.setStart(node, i);
              range.setEnd(node, i + needle.length);
              const r = range.getBoundingClientRect();
              const ctxStart = Math.max(0, i - 40);
              results.push({
                match: text.substr(i, needle.length),
                context: text.substr(ctxStart, needle.length + 80),
                bounds: {x: r.x, y: r.y, width: r.width, height: r.height}
              });
              i += needle.length;
            }
          }
          return results;
        })(\(BrowserScripts.quote(query)), \(caseSensitive ? "true" : "false"), \(limit))
        """
        return try await runJS(js)
    }

    // MARK: - Network log

    /// Recent fetch/XHR calls seen by the in-page shim, newest last.
    func networkLog(limit: Int) async throws -> Any? {
        let js = """
        (function(n){
          const a = window.__mcpNet || [];
          return a.slice(Math.max(0, a.length - n));
        })(\(limit))
        """
        return try await runJS(js)
    }

    /// Recent console messages and uncaught errors captured by the
    /// in-page shim, newest last. Optional `level` filter ("error"
    /// includes uncaught exceptions and rejections too).
    func consoleLogs(limit: Int, level: String?) async throws -> Any? {
        let levelArg = level.map { "\"\($0)\"" } ?? "null"
        let js = """
        (function(n, lv){
          let a = window.__mcpConsole || [];
          if (lv) {
            if (lv === 'error') a = a.filter(e => e.level === 'error' || e.level === 'exception' || e.level === 'rejection');
            else a = a.filter(e => e.level === lv);
          }
          return a.slice(Math.max(0, a.length - n));
        })(\(limit), \(levelArg))
        """
        return try await runJS(js)
    }
}
