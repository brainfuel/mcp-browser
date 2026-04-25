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
}
