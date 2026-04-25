//
//  BrowserTab+Agent.swift
//  MCP Browser
//
//  Per-page agent integrations: the cursor-overlay highlight, the
//  sensitive-domain submit interceptor, and the recorder gate.
//
//  Each is split into:
//    * an in-page user script (declared in `BrowserScripts`),
//    * a Swift method that pushes state into the page on nav commit,
//    * a Swift handler invoked by `ScriptMessageProxy` when the page
//      sends a message back.
//

import Foundation
import WebKit

extension BrowserTab {

    // MARK: - Agent cursor

    /// Flash a blue overlay on the element matching `selector` for
    /// `durationMs`. Best-effort; silently does nothing if the
    /// selector doesn't resolve.
    func highlightSelector(_ selector: String, durationMs: Int = 900) async {
        let js = """
        (function(sel, ms){
          const el = document.querySelector(sel);
          if (!el) return;
          const r = el.getBoundingClientRect();
          if (!r.width && !r.height) return;
          const o = document.createElement('div');
          o.style.cssText = [
            'position:fixed','z-index:2147483647','pointer-events:none',
            'left:' + (r.left - 4) + 'px',
            'top:' + (r.top - 4) + 'px',
            'width:' + (r.width + 8) + 'px',
            'height:' + (r.height + 8) + 'px',
            'border:2px solid #3b82f6',
            'border-radius:6px',
            'box-shadow:0 0 0 3px rgba(59,130,246,.30), 0 0 18px rgba(59,130,246,.45)',
            'background:rgba(59,130,246,.08)',
            'transition:opacity .35s ease-out'
          ].join(';');
          document.documentElement.appendChild(o);
          setTimeout(function(){
            o.style.opacity = '0';
            setTimeout(function(){ o.remove(); }, 380);
          }, ms);
        })(\(BrowserScripts.quote(selector)), \(durationMs))
        """
        _ = try? await runJS(js)
    }

    // MARK: - State push

    /// Re-evaluate the active agent state and push it into the page.
    /// Called when settings change mid-session so the currently-loaded
    /// page picks up new values without a reload.
    func applyAgentStateExternally() {
        applyAgentStateToPage()
        applyRecordingStateToPage()
    }

    /// Push the sensitive-domain list and confirm flag into the page so
    /// the in-page interceptor has current values.
    func applyAgentStateToPage() {
        let state = delegate?.browserTabAgentState(for: self) ?? .disabled
        guard let data = try? JSONSerialization.data(withJSONObject: state.sensitiveDomains, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        window.__mcpSensitiveList = \(json);
        window.__mcpConfirmEnabled = \(state.confirmEnabled ? "true" : "false");
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Push `window.__mcpRecording = on` into the page so the recorder
    /// user script starts/stops forwarding events.
    func applyRecordingStateToPage() {
        let on = delegate?.browserTabIsRecording(self) ?? false
        webView.evaluateJavaScript(
            "window.__mcpRecording = \(on ? "true" : "false");",
            completionHandler: nil
        )
    }

    // MARK: - Inbound messages

    /// A sensitive page wants to submit a form. Defer to the presenter
    /// for the user-facing prompt, then poke the page to re-submit or
    /// cancel based on the answer.
    func presentSubmitConfirmation(key: String, action: String, host: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let confirmed = await self.presenter?.confirmSubmit(host: host, action: action) ?? false
            let js = confirmed
                ? "window.__mcpFinishConfirm && window.__mcpFinishConfirm(\(BrowserScripts.quote(key)))"
                : "window.__mcpCancelConfirm && window.__mcpCancelConfirm(\(BrowserScripts.quote(key)))"
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// Forward a recorder event from the in-page listener to the
    /// delegate. Each recorder event maps 1:1 to an MCP tool call.
    func handleRecordedEvent(kind: String, payload: [String: Any]) {
        var args: [String: Any] = [:]
        let tool: String
        switch kind {
        case "click":
            tool = "click"
            if let s = payload["selector"] as? String { args["selector"] = s }
        case "fill":
            tool = "fill"
            if let s = payload["selector"] as? String { args["selector"] = s }
            if let v = payload["value"] as? String { args["value"] = v }
        case "submit":
            tool = "submit"
            if let s = payload["selector"] as? String { args["selector"] = s }
        default:
            return
        }
        delegate?.browserTab(self, didCaptureEvent: tool, args: args)
    }
}
