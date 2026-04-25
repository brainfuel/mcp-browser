//
//  MCPToolCatalog.swift
//  MCP Browser
//
//  Single source of truth for the set of tools the registry exposes.
//  Adding a new tool: declare a `MCPTool`-conforming type and append
//  one `AnyMCPTool(...)` line below. The descriptors `tools/list`
//  returns and the dispatch in `tools/call` are both derived from this.
//

import Foundation

@MainActor
enum MCPToolCatalog {

    /// The full ordered list of tools. Order is preserved in the
    /// descriptor list so clients see a stable surface.
    static let all: [AnyMCPTool] = [
        // Navigation
        AnyMCPTool(NavigateTool.self),
        AnyMCPTool(BackTool.self),
        AnyMCPTool(ForwardTool.self),
        AnyMCPTool(ReloadTool.self),
        AnyMCPTool(CurrentURLTool.self),
        AnyMCPTool(CurrentTitleTool.self),

        // Page content
        AnyMCPTool(ReadTextTool.self),
        AnyMCPTool(EvalJSTool.self),
        AnyMCPTool(ScreenshotTool.self),
        AnyMCPTool(RenderHTMLTool.self),

        // DOM interaction
        AnyMCPTool(ClickTool.self),
        AnyMCPTool(FillTool.self),
        AnyMCPTool(SubmitTool.self),
        AnyMCPTool(WaitForTool.self),
        AnyMCPTool(ScrollTool.self),

        // Inspection
        AnyMCPTool(GetElementTool.self),
        AnyMCPTool(ListLinksTool.self),
        AnyMCPTool(ListFormsTool.self),
        AnyMCPTool(AccessibilityTreeTool.self),
        AnyMCPTool(FindInPageTool.self),

        // Tabs
        AnyMCPTool(NewTabTool.self),
        AnyMCPTool(CloseTabTool.self),
        AnyMCPTool(SwitchTabTool.self),
        AnyMCPTool(ListTabsTool.self),

        // Files / network
        AnyMCPTool(DownloadTool.self),
        AnyMCPTool(UploadFileTool.self),
        AnyMCPTool(PDFExportTool.self),
        AnyMCPTool(NetworkLogTool.self),

        // Cookies / session
        AnyMCPTool(GetCookiesTool.self),
        AnyMCPTool(SetCookieTool.self),
        AnyMCPTool(ClearSessionTool.self),
    ]

    /// `tools/list` payload, derived from `all`.
    static let descriptors: [[String: Any]] = all.map(\.descriptor.asDictionary)

    private static let byName: [String: AnyMCPTool] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.descriptor.name, $0) }
    )

    /// Look up a tool by its public name. Throws an RPC error matching
    /// the JSON-RPC spec for unknown methods so the registry doesn't
    /// have to translate.
    static func tool(named name: String) throws -> AnyMCPTool {
        guard let t = byName[name] else {
            throw RPCError(code: -32601, message: "unknown tool: \(name)")
        }
        return t
    }
}
