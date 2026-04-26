//
//  MCPHost.swift
//  MCP Browser
//
//  The single dependency surface the MCP tool registry needs at run
//  time. Replaces the previous five separate `() -> X?` closures with
//  one weakly-held protocol — and gives tools a clean home for
//  "where do I get the active browser / settings / log?" without
//  threading parameters everywhere.
//

import Foundation

@MainActor
protocol MCPHost: AnyObject {
    var activeBrowser: BrowserTab?    { get }
    var activeTabs:    BrowserWindow? { get }
    var agentSettings: AgentSettings  { get }
    var actionLog:     ActionLog      { get }
    var pip:           PipController  { get }
    var bookmarks:     BookmarkStore  { get }
}

extension MCPHost {
    /// The active browser, or an RPC error if nothing is registered.
    func requireActiveBrowser() throws -> BrowserTab {
        guard let b = activeBrowser else {
            throw RPCError(code: -32000, message: "no active browser window")
        }
        return b
    }

    /// The active window's tabs container, or an RPC error.
    func requireActiveTabs() throws -> BrowserWindow {
        guard let t = activeTabs else {
            throw RPCError(code: -32000, message: "no active browser window")
        }
        return t
    }
}
