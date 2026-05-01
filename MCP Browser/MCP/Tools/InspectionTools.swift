//
//  InspectionTools.swift
//  MCP Browser
//

import Foundation

enum GetElementTool: MCPTool {
    struct Args: Decodable { let selector: String }
    static let descriptor = ToolDescriptor(
        name: "get_element",
        description: "Inspect a single element: tag, text, value, attributes, and bounding rect. Returns null if not found.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string"]],
            "required": ["selector"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let any = try await host.requireActiveBrowser().getElement(selector: args.selector)
        return .json(any)
    }
}

enum ListLinksTool: MCPTool {
    struct Args: Decodable { let limit: Int? }
    static let descriptor = ToolDescriptor(
        name: "list_links",
        description: "Return all anchor links on the page as {text, href}. Cheaper than read_text for navigation.",
        inputSchema: [
            "type": "object",
            "properties": ["limit": ["type": "integer", "description": "Max links to return. Default 200."]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().listLinks(limit: args.limit ?? 200))
    }
}

enum ListFormsTool: MCPTool {
    static let descriptor = ToolDescriptor(
        name: "list_forms",
        description: "Return all forms with their fields, types, values, and best-effort labels."
    )
    static func execute(_ args: EmptyArgs, host: any MCPHost) async throws -> ToolOutput {
        .json(try await host.requireActiveBrowser().listForms())
    }
}

enum AccessibilityTreeTool: MCPTool {
    struct Args: Decodable { let max_depth: Int?; let max_nodes: Int? }
    static let descriptor = ToolDescriptor(
        name: "accessibility_tree",
        description: "Return a lightweight accessibility snapshot built from the DOM (role, name, tag, children). Better than read_text for structured navigation.",
        inputSchema: [
            "type": "object",
            "properties": [
                "max_depth": ["type": "integer", "description": "Default 20."],
                "max_nodes": ["type": "integer", "description": "Default 2000."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let any = try await host.requireActiveBrowser().accessibilityTree(
            maxDepth: args.max_depth ?? 20,
            maxNodes: args.max_nodes ?? 2000
        )
        return .json(any)
    }
}

enum InspectPageTool: MCPTool {
    struct Args: Decodable {
        let max_depth: Int?
        let max_nodes: Int?
        let force_screenshot: Bool?
    }
    static let descriptor = ToolDescriptor(
        name: "inspect_page",
        description: "Recommended starting point for \"what's on this page?\". Returns the accessibility tree plus a quality score (good / weak / poor) computed from how many interactive elements have accessible names. When the score is weak or poor — typical on canvas-heavy or aria-poor sites — automatically also returns a screenshot so the model can fall back to vision. Cheap on well-built sites, robust on bad ones. Use this in preference to calling accessibility_tree + screenshot separately.",
        inputSchema: [
            "type": "object",
            "properties": [
                "max_depth":        ["type": "integer", "description": "Tree depth cap. Default 20."],
                "max_nodes":        ["type": "integer", "description": "Tree node cap. Default 2000."],
                "force_screenshot": ["type": "boolean", "description": "Include a screenshot regardless of score. Default false."]
            ]
        ]
    )

    /// Roles in the lightweight a11y tree that count as interactive surfaces
    /// for scoring. Matches the role vocabulary `accessibilityTree` emits.
    private static let interactiveRoles: Set<String> = [
        "button", "link", "textbox", "combobox", "checkbox", "radio",
        "switch", "slider", "menuitem", "menuitemcheckbox", "menuitemradio",
        "tab", "option", "searchbox", "spinbutton"
    ]

    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let tab = try host.requireActiveBrowser()
        let tree = try await tab.accessibilityTree(
            maxDepth: args.max_depth ?? 20,
            maxNodes: args.max_nodes ?? 2000
        )
        let summary = score(tree: tree)
        let needsScreenshot = (args.force_screenshot ?? false) || summary.score != "good"

        var payload: [String: Any] = [
            "tree": tree ?? NSNull(),
            "accessibility": summary.asDictionary,
            "screenshot_included": needsScreenshot
        ]
        if needsScreenshot, args.force_screenshot == true {
            payload["screenshot_reason"] = "force_screenshot=true"
        } else if needsScreenshot {
            payload["screenshot_reason"] = "accessibility score is \(summary.score)"
        }

        var content: [ToolOutput.Content] = [.text(JSONHelpers.stringify(payload))]
        if needsScreenshot {
            let png = try await tab.screenshotPNG()
            content.append(.image(base64: png.base64EncodedString(), mime: "image/png"))
        }
        return ToolOutput(content: content, isError: false)
    }

    // MARK: - Scoring

    struct Summary {
        let score: String          // "good" | "weak" | "poor"
        let interactiveCount: Int
        let namedCount: Int
        let totalNodes: Int
        let reasons: [String]

        var namedRatio: Double {
            interactiveCount == 0 ? 0 : Double(namedCount) / Double(interactiveCount)
        }
        var asDictionary: [String: Any] {
            [
                "score":             score,
                "interactive_count": interactiveCount,
                "named_count":       namedCount,
                "named_ratio":       (namedRatio * 100).rounded() / 100, // 2dp
                "total_nodes":       totalNodes,
                "reasons":           reasons
            ]
        }
    }

    /// Walk the lightweight a11y tree counting interactive nodes and how
    /// many of them have a non-empty accessible name. The thresholds are
    /// starting points — tune against real sites once we have telemetry.
    /// Exposed (internal) so the URL-bar indicator can reuse the same
    /// scoring code path the agent sees.
    static func score(tree: Any?) -> Summary {
        var interactive = 0
        var named = 0
        var total = 0

        func walk(_ node: Any?) {
            guard let dict = node as? [String: Any] else { return }
            total += 1
            let role = (dict["role"] as? String)?.lowercased() ?? ""
            let name = (dict["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if interactiveRoles.contains(role) {
                interactive += 1
                if !name.isEmpty { named += 1 }
            }
            if let kids = dict["children"] as? [Any] {
                for k in kids { walk(k) }
            }
        }
        walk(tree)

        let ratio = interactive == 0 ? 0 : Double(named) / Double(interactive)
        var reasons: [String] = []
        let score: String

        if interactive == 0 {
            score = "poor"
            reasons.append("no interactive elements found in the accessibility tree")
        } else if ratio < 0.4 {
            score = "poor"
            reasons.append("\(named)/\(interactive) interactive elements have accessible names (\(Int(ratio * 100))%)")
        } else if interactive < 5 || ratio < 0.8 {
            score = "weak"
            if interactive < 5 {
                reasons.append("only \(interactive) interactive elements found")
            }
            if ratio < 0.8 {
                reasons.append("\(named)/\(interactive) interactive elements have accessible names (\(Int(ratio * 100))%)")
            }
        } else {
            score = "good"
            reasons.append("\(interactive) interactive elements, \(named) with accessible names")
        }
        if total < 20 {
            reasons.append("tree is small (\(total) nodes) — page may be canvas-heavy or still loading")
        }
        return Summary(
            score: score,
            interactiveCount: interactive,
            namedCount: named,
            totalNodes: total,
            reasons: reasons
        )
    }
}

enum FindInPageTool: MCPTool {
    struct Args: Decodable {
        let query: String
        let case_sensitive: Bool?
        let limit: Int?
    }
    static let descriptor = ToolDescriptor(
        name: "find_in_page",
        description: "Find every occurrence of `query` in the page text. Returns {match, context, bounds} entries.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query":          ["type": "string"],
                "case_sensitive": ["type": "boolean"],
                "limit":          ["type": "integer", "description": "Default 200."]
            ],
            "required": ["query"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.query.isEmpty else { throw RPCError(code: -32602, message: "missing `query`") }
        let any = try await host.requireActiveBrowser().findInPage(
            query: args.query,
            caseSensitive: args.case_sensitive ?? false,
            limit: args.limit ?? 200
        )
        return .json(any)
    }
}
