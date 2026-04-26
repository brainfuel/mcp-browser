//
//  DOMTools.swift
//  MCP Browser
//

import Foundation

enum ClickTool: MCPTool {
    struct Args: Decodable { let selector: String }
    static let descriptor = ToolDescriptor(
        name: "click",
        description: "Click an element matched by a CSS selector.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string", "description": "CSS selector for the target element."]],
            "required": ["selector"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let hit = try await host.requireActiveBrowser().click(selector: args.selector)
        return .text(hit ? "clicked" : "not found", isError: !hit)
    }
}

enum HoverTool: MCPTool {
    struct Args: Decodable { let selector: String }
    static let descriptor = ToolDescriptor(
        name: "hover",
        description: "Move the pointer over an element matched by a CSS selector. Dispatches pointerover/mouseover/mouseenter/mousemove so JS hover handlers (tooltips, dropdowns, hover menus) fire.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string"]],
            "required": ["selector"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let hit = try await host.requireActiveBrowser().hover(selector: args.selector)
        return .text(hit ? "hovered" : "not found", isError: !hit)
    }
}

enum DialogTool: MCPTool {
    struct Args: Decodable {
        let action: String?
        let prompt_text: String?
        let apply_to: String?
        let clear: Bool?
    }
    static let descriptor = ToolDescriptor(
        name: "dialog",
        description: "Pre-arm or inspect handling of JS dialogs (alert, confirm, prompt). Set `action` to \"accept\" or \"dismiss\" to install a handler before triggering the dialog. `prompt_text` is the value returned for prompt() on accept. `apply_to` is \"next\" (default, one-shot) or \"all\" (persistent until cleared). Pass `clear: true` to remove an installed handler. With no args, returns the current handler and a log of recent dialog events (cleared on navigation).",
        inputSchema: [
            "type": "object",
            "properties": [
                "action":      ["type": "string", "enum": ["accept", "dismiss"]],
                "prompt_text": ["type": "string"],
                "apply_to":    ["type": "string", "enum": ["next", "all"]],
                "clear":       ["type": "boolean"]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let tab = try host.requireActiveBrowser()
        if args.clear == true {
            tab.dialogPolicy = nil
        } else if let action = args.action {
            let act: BrowserTab.DialogPolicy.Action
            switch action {
            case "accept":  act = .accept
            case "dismiss": act = .dismiss
            default: throw RPCError(code: -32602, message: "invalid `action`")
            }
            let once = (args.apply_to ?? "next") != "all"
            tab.dialogPolicy = BrowserTab.DialogPolicy(
                action: act, promptText: args.prompt_text, once: once
            )
        }
        let policy: Any = tab.dialogPolicy.map { p -> [String: Any] in
            var d: [String: Any] = ["action": p.action == .accept ? "accept" : "dismiss",
                                    "apply_to": p.once ? "next" : "all"]
            if let t = p.promptText { d["prompt_text"] = t }
            return d
        } ?? NSNull()
        let log: [[String: Any]] = tab.dialogLog.map { e in
            var d: [String: Any] = [
                "kind": e.kind, "message": e.message,
                "response": e.response, "at": e.at.timeIntervalSince1970
            ]
            if let dp = e.defaultPrompt { d["default"] = dp }
            if let r = e.returnedText  { d["returned"] = r }
            return d
        }
        return .json(["policy": policy, "events": log])
    }
}

enum FillTool: MCPTool {
    struct Args: Decodable { let selector: String; let value: String }
    static let descriptor = ToolDescriptor(
        name: "fill",
        description: "Set the value of an input, textarea, or contenteditable matched by a CSS selector. Dispatches input/change events.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string"],
                "value":    ["type": "string"]
            ],
            "required": ["selector", "value"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.selector.isEmpty else { throw RPCError(code: -32602, message: "missing `selector`") }
        let hit = try await host.requireActiveBrowser().fill(selector: args.selector, value: args.value)
        return .text(hit ? "filled" : "not found", isError: !hit)
    }
}

enum SubmitTool: MCPTool {
    struct Args: Decodable { let selector: String? }
    static let descriptor = ToolDescriptor(
        name: "submit",
        description: "Submit a form. If `selector` is given it should match a form or an element inside one; otherwise submits the form containing document.activeElement.",
        inputSchema: [
            "type": "object",
            "properties": ["selector": ["type": "string", "description": "Optional. Form or descendant element selector."]]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let ok = try await host.requireActiveBrowser().submit(selector: args.selector)
        return .text(ok ? "submitted" : "no form", isError: !ok)
    }
}

enum PressKeyTool: MCPTool {
    struct Args: Decodable { let key: String; let selector: String?; let modifiers: [String]? }
    static let descriptor = ToolDescriptor(
        name: "press_key",
        description: "Dispatch keydown/keypress/keyup on a target element. With `selector` omitted, dispatches on document.activeElement. `key` is a KeyboardEvent.key value (e.g. \"Enter\", \"Tab\", \"Escape\", \"ArrowDown\", \"a\"). `modifiers` accepts any of: ctrl, shift, alt, meta (cmd).",
        inputSchema: [
            "type": "object",
            "properties": [
                "key":       ["type": "string"],
                "selector":  ["type": "string", "description": "Optional. Defaults to document.activeElement."],
                "modifiers": ["type": "array", "items": ["type": "string"], "description": "Optional. ctrl, shift, alt, meta."]
            ],
            "required": ["key"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        guard !args.key.isEmpty else { throw RPCError(code: -32602, message: "missing `key`") }
        let ok = try await host.requireActiveBrowser().pressKey(
            selector: args.selector, key: args.key, modifiers: args.modifiers ?? []
        )
        return .text(ok ? "pressed" : "no target", isError: !ok)
    }
}

enum TypeTextTool: MCPTool {
    struct Args: Decodable { let text: String; let selector: String? }
    static let descriptor = ToolDescriptor(
        name: "type_text",
        description: "Type a string character-by-character into a target element, dispatching keydown/input/keyup per char so JS handlers (autocomplete, mention pickers) fire. Appends to existing value. With `selector` omitted, types into document.activeElement.",
        inputSchema: [
            "type": "object",
            "properties": [
                "text":     ["type": "string"],
                "selector": ["type": "string", "description": "Optional. Defaults to document.activeElement."]
            ],
            "required": ["text"]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let ok = try await host.requireActiveBrowser().typeText(selector: args.selector, text: args.text)
        return .text(ok ? "typed" : "no target", isError: !ok)
    }
}

enum WaitForTool: MCPTool {
    struct Args: Decodable {
        let selector: String?
        let url: String?
        let idle: Bool?
        let network_idle: Bool?
        let idle_ms: Int?
        let timeout_ms: Int?
    }
    static let descriptor = ToolDescriptor(
        name: "wait_for",
        description: "Wait for a condition to hold. Provide exactly one of `selector`, `url` (substring match), `idle: true` (page finishes loading), or `network_idle: true` (no fetch/XHR for `idle_ms`, default 500). All wait up to `timeout_ms`.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector":     ["type": "string"],
                "url":          ["type": "string"],
                "idle":         ["type": "boolean"],
                "network_idle": ["type": "boolean", "description": "Wait until no fetch/XHR has been in-flight or completed for `idle_ms` ms."],
                "idle_ms":      ["type": "integer", "description": "Quiet window for network_idle. Default 500."],
                "timeout_ms":   ["type": "integer", "description": "Default 10000."]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let timeout = args.timeout_ms ?? 10_000
        let browser = try host.requireActiveBrowser()
        let ok: Bool
        if let sel = args.selector, !sel.isEmpty {
            ok = try await browser.waitForSelector(sel, timeoutMs: timeout)
        } else if let url = args.url, !url.isEmpty {
            ok = try await browser.waitForURL(url, timeoutMs: timeout)
        } else if args.idle == true {
            ok = try await browser.waitForIdle(timeoutMs: timeout)
        } else if args.network_idle == true {
            ok = try await browser.waitForNetworkIdle(idleMs: args.idle_ms ?? 500, timeoutMs: timeout)
        } else {
            throw RPCError(code: -32602, message: "wait_for requires one of `selector`, `url`, `idle:true`, or `network_idle:true`")
        }
        return .text(ok ? "matched" : "timeout", isError: !ok)
    }
}

enum ScrollTool: MCPTool {
    struct Args: Decodable {
        let selector: String?
        let x: Double?; let y: Double?
        let dx: Double?; let dy: Double?
    }
    static let descriptor = ToolDescriptor(
        name: "scroll",
        description: "Scroll the page. Pass `selector` to scroll an element into view, `x`+`y` for absolute position, or `dx`+`dy` for a delta.",
        inputSchema: [
            "type": "object",
            "properties": [
                "selector": ["type": "string"],
                "x":  ["type": "number"], "y":  ["type": "number"],
                "dx": ["type": "number"], "dy": ["type": "number"]
            ]
        ]
    )
    static func execute(_ args: Args, host: any MCPHost) async throws -> ToolOutput {
        let ok = try await host.requireActiveBrowser().scroll(
            selector: args.selector,
            x: args.x, y: args.y, dx: args.dx, dy: args.dy
        )
        return .text(ok ? "ok" : "nothing to do", isError: !ok)
    }
}
