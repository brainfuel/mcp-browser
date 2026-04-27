//
//  MCPConfigPatcher.swift
//  MCP Browser
//
//  Pure functions for editing MCP client config files. Transport- and
//  filesystem-agnostic — callers supply the bytes, we return the bytes.
//  The actual reads/writes live in `MCPRegistrar` so sandboxed and
//  unsandboxed hosts can share this logic.
//
//  JSON: standard `mcpServers.<name>` shape used by Claude / Cursor / Code.
//  TOML: `[mcp_servers.<name>]` table used by Codex CLI. We only support
//  patching/removing one named section, preserving the rest of the file.
//

import Foundation

enum MCPConfigPatcher {

    enum PatchError: LocalizedError {
        case invalidJSON
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidJSON:           return "Existing config file is not valid JSON."
            case .writeFailed(let s):    return "Failed to update config: \(s)"
            }
        }
    }

    // MARK: - Detection

    /// True if `data` already references our server. Used to drive the
    /// install/remove button state without re-reading.
    static func isInstalled(in data: Data?, format: MCPClient.Format, name: String) -> Bool {
        guard let data else { return false }
        switch format {
        case .json:
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = obj["mcpServers"] as? [String: Any] else { return false }
            return servers[name] != nil
        case .toml:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return findTOMLSection(in: text, name: name) != nil
        }
    }

    // MARK: - JSON

    /// Returns the bytes of an updated config that includes our server.
    /// Preserves any unrelated keys that were already present.
    static func upsertJSON(existing: Data?, spec: MCPServerSpec) throws -> Data {
        var root: [String: Any] = [:]
        if let existing,
           let obj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = obj
        } else if existing != nil {
            // File exists but isn't valid JSON — refuse to clobber.
            throw PatchError.invalidJSON
        }
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[spec.name] = jsonEntry(for: spec.transport)
        root["mcpServers"] = servers
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func removeJSON(existing: Data?, name: String) throws -> Data? {
        guard let existing,
              var root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            return nil
        }
        guard var servers = root["mcpServers"] as? [String: Any],
              servers[name] != nil else {
            return nil
        }
        servers.removeValue(forKey: name)
        root["mcpServers"] = servers
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func jsonEntry(for transport: MCPTransport) -> [String: Any] {
        switch transport {
        case .stdio(let binary, let args):
            return ["command": binary.path, "args": args]
        case .http(let url, let headers):
            var entry: [String: Any] = ["type": "http", "url": url]
            if !headers.isEmpty { entry["headers"] = headers }
            return entry
        }
    }

    // MARK: - TOML

    /// Updated TOML text that includes our `[mcp_servers.<name>]` block.
    /// Replaces an existing block if present; otherwise appends.
    static func upsertTOML(existing: String?, spec: MCPServerSpec) -> String {
        let block = tomlBlock(for: spec)
        let text = existing ?? ""
        if let range = findTOMLSection(in: text, name: spec.name) {
            var out = text
            out.replaceSubrange(range, with: block)
            return out
        }
        if text.isEmpty { return block }
        let separator = text.hasSuffix("\n") ? "\n" : "\n\n"
        return text + separator + block
    }

    static func removeTOML(existing: String?, name: String) -> String? {
        guard let text = existing,
              let range = findTOMLSection(in: text, name: name) else { return nil }
        var out = text
        out.replaceSubrange(range, with: "")
        // Tidy up any blank-line run we just opened up.
        while out.contains("\n\n\n") {
            out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return out
    }

    /// Build the literal text for one `[mcp_servers.<name>]` block.
    /// Always terminated by a newline so the next section starts cleanly.
    private static func tomlBlock(for spec: MCPServerSpec) -> String {
        var lines: [String] = ["[mcp_servers.\(quoteTOMLKeyIfNeeded(spec.name))]"]
        switch spec.transport {
        case .stdio(let binary, let args):
            lines.append("command = \(escapeTOMLString(binary.path))")
            lines.append("args = [\(args.map(escapeTOMLString).joined(separator: ", "))]")
        case .http(let url, let headers):
            lines.append("url = \(escapeTOMLString(url))")
            if !headers.isEmpty {
                let inner = headers
                    .sorted(by: { $0.key < $1.key })
                    .map { "\(quoteTOMLKeyIfNeeded($0.key)) = \(escapeTOMLString($0.value))" }
                    .joined(separator: ", ")
                lines.append("headers = { \(inner) }")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Locate `[mcp_servers.<name>]` and the following body, up to (but
    /// not including) the next top-level table header or end-of-file.
    /// Returns the substring range so callers can replace or remove it.
    private static func findTOMLSection(in text: String, name: String) -> Range<String.Index>? {
        // Match either `[mcp_servers.name]` or `[mcp_servers."name"]`.
        // We scan line-by-line so we don't need a real TOML parser.
        let header1 = "[mcp_servers.\(name)]"
        let header2 = "[mcp_servers.\"\(name)\"]"

        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line == header1 || line == header2 {
                let nextSectionStart = scanToNextSection(text: text, after: lineEnd)
                return lineStart..<nextSectionStart
            }
            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }
        return nil
    }

    /// Walk forward to the start of the next `[…]` line (or EOF), so the
    /// returned range covers the entire body of the section we found.
    private static func scanToNextSection(text: String, after start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            let next = cursor < text.endIndex ? text.index(after: cursor) : cursor
            let lineEnd = text[next...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[next..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && !line.hasPrefix("[[") {
                return next
            }
            if lineEnd == text.endIndex { return text.endIndex }
            cursor = lineEnd
        }
        return text.endIndex
    }

    private static func quoteTOMLKeyIfNeeded(_ key: String) -> String {
        // Bare keys allow [A-Za-z0-9_-]; everything else needs quoting.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if key.unicodeScalars.allSatisfy({ allowed.contains($0) }) { return key }
        return "\"\(key.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func escapeTOMLString(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:   out.append(ch)
            }
        }
        out.append("\"")
        return out
    }
}
