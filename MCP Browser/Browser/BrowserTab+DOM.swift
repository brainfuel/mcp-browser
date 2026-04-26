//
//  BrowserTab+DOM.swift
//  MCP Browser
//
//  DOM-facing tool implementations: click / fill / submit / scroll,
//  read-only inspection (get_element, list_links, list_forms,
//  accessibility_tree), and the wait_for primitives. Each method maps
//  directly to one MCP tool.
//

import Foundation
import WebKit
import AppKit

extension BrowserTab {

    // MARK: - Interaction

    /// Click an element matched by CSS selector. Returns true on hit.
    func click(selector: String) async throws -> Bool {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return false;
          el.scrollIntoView({block:'center'});
          if (typeof el.click === 'function') el.click();
          else el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true}));
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    /// Hover over an element matched by CSS selector. Dispatches the
    /// pointerover/mouseover/mouseenter/mousemove sequence at the
    /// element's center so JS hover handlers (tooltips, dropdowns) fire.
    /// Returns true on hit.
    func hover(selector: String) async throws -> Bool {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return false;
          el.scrollIntoView({block:'center'});
          const r = el.getBoundingClientRect();
          const cx = r.left + r.width/2, cy = r.top + r.height/2;
          const opts = {bubbles:true, cancelable:true, clientX:cx, clientY:cy};
          el.dispatchEvent(new PointerEvent('pointerover', opts));
          el.dispatchEvent(new MouseEvent('mouseover', opts));
          el.dispatchEvent(new PointerEvent('pointerenter', opts));
          el.dispatchEvent(new MouseEvent('mouseenter', opts));
          el.dispatchEvent(new PointerEvent('pointermove', opts));
          el.dispatchEvent(new MouseEvent('mousemove', opts));
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    /// Fill an input/textarea/contenteditable with `value`. Dispatches
    /// input+change events so frameworks (React et al.) pick up the edit.
    func fill(selector: String, value: String) async throws -> Bool {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return false;
          el.focus();
          if (el.isContentEditable) {
            el.innerText = \(BrowserScripts.quote(value));
          } else {
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            if (setter) setter.call(el, \(BrowserScripts.quote(value)));
            else el.value = \(BrowserScripts.quote(value));
          }
          el.dispatchEvent(new Event('input', {bubbles:true}));
          el.dispatchEvent(new Event('change', {bubbles:true}));
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    /// Press a key (with optional modifiers) on a target element. With
    /// `selector` nil, dispatches on `document.activeElement` (or the
    /// body if nothing is focused). `key` accepts standard
    /// KeyboardEvent.key values like "Enter", "Tab", "Escape",
    /// "ArrowDown", "a", "A". Modifiers are dispatched as flags on the
    /// event. Returns true if a target was found.
    func pressKey(selector: String?, key: String, modifiers: [String]) async throws -> Bool {
        let target = selector
            .map { "document.querySelector(\(BrowserScripts.quote($0)))" }
            ?? "(document.activeElement || document.body)"
        let mods = Set(modifiers.map { $0.lowercased() })
        let ctrl  = mods.contains("ctrl")  || mods.contains("control")
        let shift = mods.contains("shift")
        let alt   = mods.contains("alt")   || mods.contains("option")
        let meta  = mods.contains("meta")  || mods.contains("cmd") || mods.contains("command")
        let js = """
        (function(){
          const el = \(target);
          if (!el) return false;
          const opts = {
            key: \(BrowserScripts.quote(key)),
            bubbles: true, cancelable: true,
            ctrlKey: \(ctrl), shiftKey: \(shift), altKey: \(alt), metaKey: \(meta)
          };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keypress', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    /// Type text into a target element a character at a time, dispatching
    /// keydown / input / keyup per character so key-event listeners fire
    /// (autocomplete, mention pickers, etc). With `selector` nil, types
    /// into `document.activeElement`. Appends to existing value.
    func typeText(selector: String?, text: String) async throws -> Bool {
        let target = selector
            .map { "document.querySelector(\(BrowserScripts.quote($0)))" }
            ?? "document.activeElement"
        let js = """
        (function(){
          const el = \(target);
          if (!el) return false;
          if (typeof el.focus === 'function') el.focus();
          const text = \(BrowserScripts.quote(text));
          const isInput = el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
          for (const ch of text) {
            const opts = {key: ch, bubbles: true, cancelable: true};
            el.dispatchEvent(new KeyboardEvent('keydown', opts));
            if (isInput) {
              const proto = el instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
              const next = (el.value || '') + ch;
              if (setter) setter.call(el, next); else el.value = next;
              el.dispatchEvent(new InputEvent('input', {bubbles:true, data: ch, inputType:'insertText'}));
            } else if (el.isContentEditable) {
              el.innerText = (el.innerText || '') + ch;
              el.dispatchEvent(new InputEvent('input', {bubbles:true, data: ch, inputType:'insertText'}));
            }
            el.dispatchEvent(new KeyboardEvent('keyup', opts));
          }
          if (isInput) el.dispatchEvent(new Event('change', {bubbles:true}));
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    // MARK: - Storage

    enum StorageKind: String { case local, session }
    enum StorageOp: String { case get, set, remove, clear, keys }

    /// Read / write `localStorage` or `sessionStorage`. With `op == .get`
    /// and no key, returns all entries. Returns whatever the requested
    /// op yielded (string, dictionary, or null).
    func storage(kind: StorageKind, op: StorageOp, key: String?, value: String?) async throws -> Any? {
        let store = kind == .local ? "localStorage" : "sessionStorage"
        let keyJS = key.map { BrowserScripts.quote($0) } ?? "null"
        let valJS = value.map { BrowserScripts.quote($0) } ?? "null"
        let js: String
        switch op {
        case .get:
            js = """
            (function(){
              const s = window.\(store);
              const k = \(keyJS);
              if (k != null) return s.getItem(k);
              const out = {};
              for (let i = 0; i < s.length; i++) {
                const kk = s.key(i);
                if (kk != null) out[kk] = s.getItem(kk);
              }
              return out;
            })()
            """
        case .set:
            js = """
            (function(){
              const k = \(keyJS); const v = \(valJS);
              if (k == null || v == null) return false;
              window.\(store).setItem(k, v);
              return true;
            })()
            """
        case .remove:
            js = """
            (function(){
              const k = \(keyJS);
              if (k == null) return false;
              window.\(store).removeItem(k);
              return true;
            })()
            """
        case .clear:
            js = "(function(){ window.\(store).clear(); return true; })()"
        case .keys:
            js = """
            (function(){
              const s = window.\(store);
              const out = [];
              for (let i = 0; i < s.length; i++) out.push(s.key(i));
              return out;
            })()
            """
        }
        return try await runJS(js)
    }

    /// Submit a form. With `selector` nil, uses the active element's
    /// nearest ancestor form.
    func submit(selector: String?) async throws -> Bool {
        let target = selector
            .map { "document.querySelector(\(BrowserScripts.quote($0)))" }
            ?? "document.activeElement"
        let js = """
        (function(){
          const el = \(target);
          if (!el) return false;
          const form = el.tagName === 'FORM' ? el : el.closest && el.closest('form');
          if (!form) return false;
          if (typeof form.requestSubmit === 'function') form.requestSubmit();
          else form.submit();
          return true;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    /// Scroll by absolute position, delta, or into view of a selector.
    func scroll(selector: String?,
                x: Double?, y: Double?,
                dx: Double?, dy: Double?) async throws -> Bool {
        let sel = selector.map { "document.querySelector(\(BrowserScripts.quote($0)))" } ?? "null"
        let js = """
        (function(){
          const el = \(sel);
          if (el) { el.scrollIntoView({block:'center', inline:'center'}); return true; }
          const X = \(BrowserScripts.quote(x)); const Y = \(BrowserScripts.quote(y));
          const DX = \(BrowserScripts.quote(dx)); const DY = \(BrowserScripts.quote(dy));
          if (X !== null && Y !== null) { window.scrollTo(X, Y); return true; }
          if (DX !== null || DY !== null) { window.scrollBy(DX || 0, DY || 0); return true; }
          return false;
        })()
        """
        return (try await runJS(js) as? Bool) ?? false
    }

    // MARK: - Inspection

    /// Inspect a single element: tag, text, value, attributes, bounds.
    /// Returns nil if the selector doesn't match.
    func getElement(selector: String) async throws -> Any? {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return null;
          const r = el.getBoundingClientRect();
          const attrs = {};
          for (const a of el.attributes) attrs[a.name] = a.value;
          return {
            tag: el.tagName.toLowerCase(),
            text: (el.innerText || '').slice(0, 4000),
            value: ('value' in el) ? el.value : null,
            attributes: attrs,
            bounds: {x:r.x, y:r.y, width:r.width, height:r.height},
            visible: !!(r.width && r.height)
          };
        })()
        """
        return try await runJS(js)
    }

    /// All `a[href]` elements with their visible text and resolved href.
    func listLinks(limit: Int) async throws -> Any? {
        let js = """
        (function(){
          const out = [];
          for (const a of document.querySelectorAll('a[href]')) {
            if (out.length >= \(limit)) break;
            out.push({text:(a.innerText||'').trim().slice(0,200), href:a.href});
          }
          return out;
        })()
        """
        return try await runJS(js)
    }

    /// All forms with their fields and best-effort labels.
    func listForms() async throws -> Any? {
        let js = """
        (function(){
          return [...document.querySelectorAll('form')].map(f => {
            const fields = [...f.querySelectorAll('input,select,textarea,button')].map(el => {
              let label = null;
              if (el.id) {
                const l = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
                if (l) label = l.innerText.trim();
              }
              if (!label) {
                const l = el.closest && el.closest('label');
                if (l) label = l.innerText.trim();
              }
              return {
                tag: el.tagName.toLowerCase(),
                type: el.type || null,
                name: el.name || null,
                value: ('value' in el) ? el.value : null,
                placeholder: el.placeholder || null,
                label
              };
            });
            return {
              action: f.action, method: (f.method || 'get').toLowerCase(),
              id: f.id || null, name: f.name || null, fields
            };
          });
        })()
        """
        return try await runJS(js)
    }

    /// Lightweight accessibility snapshot built from the DOM. Honors
    /// `aria-*` / `role` / `alt` / `title` and skips hidden subtrees.
    func accessibilityTree(maxDepth: Int, maxNodes: Int) async throws -> Any? {
        let js = """
        (function(maxDepth, maxNodes){
          let count = 0;
          const ROLE = {a:'link',button:'button',nav:'navigation',main:'main',
            header:'banner',footer:'contentinfo',h1:'heading',h2:'heading',
            h3:'heading',h4:'heading',h5:'heading',h6:'heading',img:'image',
            input:'textbox',textarea:'textbox',select:'combobox',ul:'list',
            ol:'list',li:'listitem',form:'form',label:'label',section:'region',
            article:'article',aside:'complementary'};
          function roleOf(el){
            const r = el.getAttribute('role');
            if (r) return r;
            return ROLE[el.tagName.toLowerCase()] || el.tagName.toLowerCase();
          }
          function nameOf(el){
            return el.getAttribute('aria-label')
              || el.getAttribute('alt')
              || el.getAttribute('title')
              || (el.innerText || '').trim().slice(0, 200);
          }
          function walk(el, depth){
            if (count++ >= maxNodes) return null;
            if (!el || el.nodeType !== 1) return null;
            const s = getComputedStyle(el);
            if (s.display === 'none' || s.visibility === 'hidden') return null;
            const node = {role: roleOf(el), name: nameOf(el), tag: el.tagName.toLowerCase()};
            if (el.id) node.id = el.id;
            if (depth < maxDepth) {
              const kids = [];
              for (const c of el.children) {
                const k = walk(c, depth + 1);
                if (k) kids.push(k);
              }
              if (kids.length) node.children = kids;
            }
            return node;
          }
          return walk(document.body, 0);
        })(\(maxDepth), \(maxNodes))
        """
        return try await runJS(js)
    }

    // MARK: - Waits

    /// Poll the page until `selector` matches a visible element or the
    /// timeout elapses.
    func waitForSelector(_ selector: String, timeoutMs: Int) async throws -> Bool {
        let js = """
        (function(){
          const el = document.querySelector(\(BrowserScripts.quote(selector)));
          if (!el) return false;
          const r = el.getBoundingClientRect();
          return !!(r.width && r.height);
        })()
        """
        return try await poll(timeoutMs: timeoutMs) {
            ((try? await self.runJS(js)) as? Bool) ?? false
        }
    }

    /// Wait until `currentURL.absoluteString` contains `substring`.
    func waitForURL(_ substring: String, timeoutMs: Int) async throws -> Bool {
        try await poll(timeoutMs: timeoutMs) { [weak self] in
            self?.currentURL?.absoluteString.contains(substring) ?? false
        }
    }

    /// Wait until the page is not loading and `document.readyState` is complete.
    func waitForIdle(timeoutMs: Int) async throws -> Bool {
        try await poll(timeoutMs: timeoutMs) { [weak self] in
            guard let self else { return false }
            if self.isLoading { return false }
            let state = (try? await self.runJS("document.readyState")) as? String
            return state == "complete"
        }
    }

    /// Wait until no fetch/XHR has been in-flight or completed for at
    /// least `idleMs` milliseconds, or until `timeoutMs` elapses.
    /// Reads from `window.__mcpNet`, the same buffer used by `network_log`.
    func waitForNetworkIdle(idleMs: Int, timeoutMs: Int) async throws -> Bool {
        let js = """
        (function(idle){
          const a = window.__mcpNet || [];
          const now = Date.now();
          let lastBusy = 0;
          for (const e of a) {
            if (e.duration == null) return false;            // in-flight
            const end = (e.startedAt || 0) + (e.duration || 0);
            if (end > lastBusy) lastBusy = end;
          }
          return (now - lastBusy) >= idle;
        })(\(idleMs))
        """
        return try await poll(timeoutMs: timeoutMs) {
            ((try? await self.runJS(js)) as? Bool) ?? false
        }
    }

    // MARK: - Emulation

    struct EmulationState {
        var userAgent: String?
        var width: Int?
        var height: Int?
        var zoom: Double?
    }

    /// Apply any combination of: `userAgent` (sets `customUserAgent` —
    /// pass empty string to clear), `width`+`height` (resizes the host
    /// NSWindow's content area), `zoom` (page magnification, 1.0 = 100%).
    func emulate(userAgent: String?, width: Int?, height: Int?, zoom: Double?) async throws -> EmulationState {
        if let ua = userAgent {
            webView.customUserAgent = ua.isEmpty ? nil : ua
        }
        if let z = zoom {
            webView.pageZoom = CGFloat(z)
        }
        if let w = width, let h = height, let window = webView.window {
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let chromeW = frame.width  - content.width
            let chromeH = frame.height - content.height
            let newFrame = NSRect(
                x: frame.origin.x,
                y: frame.origin.y + (frame.height - (CGFloat(h) + chromeH)),
                width:  CGFloat(w) + chromeW,
                height: CGFloat(h) + chromeH
            )
            window.setFrame(newFrame, display: true, animate: false)
        }
        return EmulationState(
            userAgent: webView.customUserAgent,
            width: width, height: height,
            zoom: Double(webView.pageZoom)
        )
    }

    // MARK: - Page metadata

    /// Aggregate page-identifying metadata: title, URL, language, charset,
    /// description, canonical link, viewport meta, OpenGraph + Twitter Card
    /// tags, generic <meta name=...> entries, and favicons.
    func pageMetadata() async throws -> Any? {
        let js = """
        (function(){
          function abs(u){ try { return new URL(u, document.baseURI).href; } catch(_) { return u; } }
          const meta = {
            url:    location.href,
            title:  document.title || null,
            lang:   document.documentElement.getAttribute('lang') || null,
            charset: document.characterSet || null,
            description: null,
            canonical:   null,
            viewport:    null,
            theme_color: null,
            og:   {},
            twitter: {},
            meta: {},
            favicons: [],
            manifest: null,
            rss: []
          };
          const metas = document.head ? document.head.querySelectorAll('meta') : [];
          for (const m of metas) {
            const name = (m.getAttribute('name') || '').toLowerCase();
            const prop = (m.getAttribute('property') || '').toLowerCase();
            const c = m.getAttribute('content');
            if (c == null) continue;
            if (name === 'description')  meta.description = c;
            else if (name === 'viewport')    meta.viewport = c;
            else if (name === 'theme-color') meta.theme_color = c;
            if (prop.startsWith('og:'))      meta.og[prop.slice(3)] = c;
            else if (name.startsWith('twitter:')) meta.twitter[name.slice(8)] = c;
            else if (name)                   meta.meta[name] = c;
          }
          const links = document.head ? document.head.querySelectorAll('link') : [];
          for (const l of links) {
            const rel = (l.getAttribute('rel') || '').toLowerCase();
            const href = l.getAttribute('href');
            if (!href) continue;
            if (rel === 'canonical') meta.canonical = abs(href);
            else if (rel === 'manifest') meta.manifest = abs(href);
            else if (rel.includes('icon')) meta.favicons.push({rel, href: abs(href), sizes: l.getAttribute('sizes') || null, type: l.getAttribute('type') || null});
            else if (rel === 'alternate' && (l.getAttribute('type') || '').includes('rss')) meta.rss.push({href: abs(href), title: l.getAttribute('title') || null});
          }
          return meta;
        })()
        """
        return try await runJS(js)
    }
}
