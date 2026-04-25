//
//  MCPServer.swift
//  MCP Browser
//
//  A minimal HTTP server that speaks MCP's JSON-RPC over POST /mcp.
//  Uses Network.framework's NWListener so it plays nicely with the
//  App Sandbox (server entitlement is enough — no BSD sockets).
//
//  Transport semantics follow the MCP "Streamable HTTP" spec but we
//  only implement the non-streaming variant: client POSTs a single
//  JSON-RPC request, server responds with `application/json`. Good
//  enough for tool calls; SSE can come later if we add notifications.
//

import Foundation
import Network

/// Entire server runs off the main actor — it's driven by Network.framework
/// callbacks on its own dispatch queue. Tool handlers hop to @MainActor
/// explicitly when they need to touch WKWebView.
nonisolated final class MCPServer: @unchecked Sendable {
    private let listener: NWListener
    private let port: UInt16
    private let tools: MCPToolRegistry
    private let queue = DispatchQueue(label: "mcp.server")

    init(
        port: UInt16,
        host: @escaping @Sendable @MainActor () -> (any MCPHost)?
    ) throws {
        self.port = port
        self.tools = MCPToolRegistry(host: host)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback-only binding. Setting requiredLocalEndpoint AND passing
        // a port to NWListener(using:on:) conflicts, so we put the full
        // address in the parameters and omit the port argument.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        self.listener = try NWListener(using: params)
    }

    func start() throws {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:    NSLog("MCP server listening on http://127.0.0.1:\(self.port)/mcp")
            case .failed(let err): NSLog("MCP server failed: \(err)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readRequest(on: conn, buffer: Data())
            case .failed, .cancelled:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Reads from the connection until we have a complete HTTP request
    /// (headers terminator + full Content-Length body), then dispatches.
    private func readRequest(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                NSLog("MCP read error: \(error)")
                conn.cancel()
                return
            }
            var buf = buffer
            if let data { buf.append(data) }

            // Split headers/body on CRLFCRLF.
            guard let split = buf.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a])) else {
                if isComplete { conn.cancel() } else { self.readRequest(on: conn, buffer: buf) }
                return
            }
            let headerData = buf.subdata(in: 0..<split.lowerBound)
            let afterHeaders = buf.subdata(in: split.upperBound..<buf.endIndex)
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                self.write(status: 400, body: "bad request", on: conn)
                return
            }

            let request = HTTPRequest(parsingHeaders: headerString)
            let contentLength = request.headers["content-length"].flatMap(Int.init) ?? 0
            if afterHeaders.count < contentLength {
                // Need more body bytes.
                self.readRequest(on: conn, buffer: buf)
                return
            }
            let body = afterHeaders.prefix(contentLength)
            self.dispatch(request: request, body: Data(body), on: conn)
        }
    }

    private func dispatch(request: HTTPRequest, body: Data, on conn: NWConnection) {
        // Health probe for humans hitting the URL.
        if request.method == "GET" && request.path == "/" {
            write(status: 200, body: "MCP Browser is running. POST JSON-RPC to /mcp\n", on: conn)
            return
        }
        guard request.method == "POST", request.path == "/mcp" else {
            write(status: 404, body: "not found\n", on: conn)
            return
        }

        Task.detached { [tools] in
            let responseJSON = await tools.handle(jsonRPCBody: body)
            self.write(status: 200, contentType: "application/json", body: responseJSON, on: conn)
        }
    }

    // MARK: - HTTP response helpers

    private func write(status: Int, contentType: String = "text/plain; charset=utf-8", body: String, on conn: NWConnection) {
        write(status: status, contentType: contentType, body: Data(body.utf8), on: conn)
    }

    private func write(status: Int, contentType: String, body: Data, on conn: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default:  reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - HTTP request parsing

private struct HTTPRequest {
    var method: String = ""
    var path: String = ""
    var headers: [String: String] = [:]

    init(parsingHeaders raw: String) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return }
        let requestLine = first.split(separator: " ")
        if requestLine.count >= 2 {
            method = String(requestLine[0])
            path = String(requestLine[1])
        }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = value
        }
    }
}
