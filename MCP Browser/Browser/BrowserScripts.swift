//
//  BrowserScripts.swift
//  MCP Browser
//
//  JavaScript snippets injected into every WKWebView at document start.
//  Kept in one place so the Swift side of BrowserTab stays focused on
//  bridging logic rather than embedded source.
//
//  Each script is idempotent (guarded by an installed flag) so repeated
//  injection is harmless. Communication back to native goes through
//  `webkit.messageHandlers.<name>.postMessage(...)`.
//

import Foundation

enum BrowserScripts {

    /// Wraps `fetch` and `XMLHttpRequest` to maintain a rolling buffer
    /// of recent requests on `window.__mcpNet`. The `network_log` MCP
    /// tool reads this buffer.
    static let networkLog = """
    (function(){
      if (window.__mcpNet) return;
      const LOG = [];
      const MAX = 500;
      window.__mcpNet = LOG;
      function push(e){ LOG.push(e); if (LOG.length > MAX) LOG.shift(); }

      const origFetch = window.fetch;
      if (origFetch) {
        window.fetch = async function(input, init){
          const url = (typeof input === 'string') ? input : (input && input.url) || '';
          const method = (init && init.method) || (input && input.method) || 'GET';
          const start = Date.now();
          const entry = {kind:'fetch', method, url, startedAt:start, status:null, duration:null, error:null};
          push(entry);
          try {
            const resp = await origFetch.apply(this, arguments);
            entry.status = resp.status;
            entry.duration = Date.now() - start;
            return resp;
          } catch(e) {
            entry.error = String(e);
            entry.duration = Date.now() - start;
            throw e;
          }
        };
      }

      const origOpen = XMLHttpRequest.prototype.open;
      const origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url){
        try { this.__mcp = {kind:'xhr', method, url: new URL(url, document.baseURI).href}; }
        catch(_) { this.__mcp = {kind:'xhr', method, url: String(url)}; }
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(){
        const e = this.__mcp || {kind:'xhr'};
        e.startedAt = Date.now();
        e.status = null;
        e.duration = null;
        push(e);
        this.addEventListener('loadend', () => {
          e.status = this.status;
          e.duration = Date.now() - e.startedAt;
        });
        return origSend.apply(this, arguments);
      };
    })();
    """

    /// Intercepts form submits on hosts that match the agent's
    /// sensitive list. Native code shows a confirmation alert and
    /// re-submits via `window.__mcpFinishConfirm(key)`.
    static let sensitiveSubmit = """
    (function(){
      if (window.__mcpSubmitInstalled) return;
      window.__mcpSubmitInstalled = true;
      window.__mcpSensitiveList = window.__mcpSensitiveList || [];
      window.__mcpConfirmEnabled = window.__mcpConfirmEnabled !== false;

      function hostIsSensitive(){
        if (!window.__mcpConfirmEnabled) return false;
        const h = (location.hostname || '').toLowerCase();
        return (window.__mcpSensitiveList || []).some(function(d){
          d = String(d || '').toLowerCase();
          if (!d) return false;
          return h === d || h.endsWith('.' + d) || h.indexOf(d) !== -1;
        });
      }

      document.addEventListener('submit', function(e){
        const f = e.target;
        if (!(f instanceof HTMLFormElement)) return;
        if (f.dataset.mcpConfirmed === '1') return;
        if (!hostIsSensitive()) return;
        e.preventDefault();
        e.stopPropagation();
        const key = 'f' + Math.random().toString(36).slice(2);
        f.dataset.mcpKey = key;
        try {
          window.webkit.messageHandlers.mcpConfirmSubmit.postMessage({
            key: key,
            action: String(f.action || ''),
            host: location.hostname || ''
          });
        } catch (_) { /* handler not wired — let it submit */ }
      }, true);

      window.__mcpFinishConfirm = function(key){
        const f = document.querySelector('form[data-mcp-key="' + key + '"]');
        if (!f) return;
        f.dataset.mcpConfirmed = '1';
        if (typeof f.requestSubmit === 'function') f.requestSubmit();
        else f.submit();
      };
      window.__mcpCancelConfirm = function(key){
        const f = document.querySelector('form[data-mcp-key="' + key + '"]');
        if (f) delete f.dataset.mcpKey;
      };
    })();
    """

    /// Listens for clicks / changes / submits when `window.__mcpRecording`
    /// is true and forwards each as a selector-based MCP tool-call entry.
    static let recorder = """
    (function(){
      if (window.__mcpRecInstalled) return;
      window.__mcpRecInstalled = true;
      if (typeof window.__mcpRecording === 'undefined') window.__mcpRecording = false;

      function esc(v){ return (window.CSS && CSS.escape) ? CSS.escape(v) : String(v).replace(/"/g, '\\\\"'); }

      function selectorFor(el){
        if (!(el instanceof Element)) return null;
        if (el.id) return '#' + esc(el.id);
        const tag = el.tagName.toLowerCase();
        const testid = el.getAttribute && el.getAttribute('data-testid');
        if (testid) return '[data-testid="' + esc(testid) + '"]';
        if (el.name) return tag + '[name="' + esc(el.name) + '"]';
        const aria = el.getAttribute && el.getAttribute('aria-label');
        if (aria) return tag + '[aria-label="' + esc(aria) + '"]';
        const parts = [];
        let cur = el;
        while (cur && cur !== document.body && cur.parentElement && parts.length < 6) {
          const parent = cur.parentElement;
          const sibs = Array.from(parent.children).filter(c => c.tagName === cur.tagName);
          let piece = cur.tagName.toLowerCase();
          if (sibs.length > 1) piece += ':nth-of-type(' + (sibs.indexOf(cur) + 1) + ')';
          parts.unshift(piece);
          cur = parent;
        }
        return parts.join(' > ');
      }

      function send(kind, payload){
        try {
          window.webkit.messageHandlers.mcpRecord.postMessage(
            Object.assign({kind}, payload)
          );
        } catch (_) { /* handler not wired */ }
      }

      document.addEventListener('click', function(e){
        if (!window.__mcpRecording) return;
        const sel = selectorFor(e.target);
        if (sel) send('click', {selector: sel});
      }, true);

      document.addEventListener('change', function(e){
        if (!window.__mcpRecording) return;
        const el = e.target;
        if (!el || !('value' in el)) return;
        const sel = selectorFor(el);
        if (sel) send('fill', {selector: sel, value: String(el.value || '')});
      }, true);

      document.addEventListener('submit', function(e){
        if (!window.__mcpRecording) return;
        const sel = selectorFor(e.target);
        if (sel) send('submit', {selector: sel});
      }, true);
    })();
    """

    /// JSON-encodes a Swift string for safe interpolation into JS source.
    static func quote(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
        var str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        str.removeFirst(); str.removeLast()
        return str
    }

    /// Stringify a `Double?` for JS interpolation: nil and non-finite
    /// values become the literal `null`.
    static func quote(_ n: Double?) -> String {
        guard let n, n.isFinite else { return "null" }
        return String(n)
    }
}
