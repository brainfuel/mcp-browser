//
//  CookieConsent.swift
//  MCP Browser
//
//  Auto-handles cookie consent banners. Two layers stacked together:
//
//   1. CSS hide — a curated set of vendor-specific selectors that
//      visually remove banners. Cheap, can't break page logic, but
//      doesn't actually record consent.
//
//   2. Rule-based click — a small database of CMP (Consent Management
//      Platform) rules that find and click the right button: accept,
//      reject, or reject-non-essential. This *does* record consent so
//      the banner stays gone on subsequent visits.
//
//  Patterned loosely after DuckDuckGo's open-source AutoConsent. We
//  ship our own minimal rule set so we don't have to bundle and track
//  upstream releases yet — replacing this with the real AutoConsent
//  bundle is a future task.
//

import Foundation

/// User-selectable behavior for cookie banners. Persisted as the raw
/// string under `BrowserTab.cookieConsentPolicyKey`.
enum CookieConsentPolicy: String, CaseIterable, Codable, Identifiable {
    case off                = "off"
    case hideOnly           = "hide_only"
    case declineOptional    = "decline_optional"
    case declineAll         = "decline_all"
    case acceptAll          = "accept_all"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:             return "Off"
        case .hideOnly:        return "Hide only"
        case .declineOptional: return "Decline non-essential"
        case .declineAll:      return "Decline all"
        case .acceptAll:       return "Accept all"
        }
    }

    var help: String {
        switch self {
        case .off:
            return "Don't touch cookie banners. Use the site's own controls."
        case .hideOnly:
            return "Visually hide common banners with CSS. Doesn't record a choice — banners come back next visit."
        case .declineOptional:
            return "Click \"reject non-essential\" / \"only necessary\" where available; falls back to a full decline."
        case .declineAll:
            return "Click \"reject all\" wherever available. Strictest privacy. Some sites may not work."
        case .acceptAll:
            return "Click \"accept all\". Minimum friction, maximum tracking — pick this if you don't care."
        }
    }

    /// JS string passed into `__mcpConsent.run(...)` so the page-side
    /// rules know which button to look for.
    var jsActionToken: String {
        switch self {
        case .off, .hideOnly:    return "none"
        case .acceptAll:         return "accept_all"
        case .declineOptional:   return "decline_optional"
        case .declineAll:        return "decline_all"
        }
    }

    /// Whether the click-based JS layer should run for this policy.
    var runsClickLayer: Bool {
        switch self {
        case .off, .hideOnly:    return false
        default:                 return true
        }
    }

    /// Whether the CSS-hide layer should be applied for this policy.
    /// On for everything except `.off` — even when the click layer runs,
    /// CSS hide acts as a backstop for vendors we don't have rules for.
    var hidesViaCSS: Bool { self != .off }
}

// MARK: - Injected sources

enum CookieConsentScripts {

    /// CSS rules that hide common cookie-consent overlays. Curated subset
    /// of the EasyList Cookie List patterns. Applied as a WKUserStyleSheet
    /// when the policy is anything other than `.off`.
    static let hideCSS = """
    /* Vendor-specific overlays */
    #onetrust-banner-sdk, #onetrust-consent-sdk, .onetrust-pc-dark-filter,
    #CybotCookiebotDialog, #CybotCookiebotDialogBodyUnderlay,
    #didomi-host, #didomi-popup, .didomi-popup-open,
    .qc-cmp2-container, #qcCmpUi, .qc-cmp2-summary-buttons,
    #truste-consent-track, #truste-consent-content, .trustarc-banner-overlay, #consent_blackbar,
    #cookie-law-info-bar, .cli-modal, .cky-consent-container, .cky-modal,
    #klaro, .klaro, .cm-modal, .cookie-modal,
    #iubenda-cs-banner, .iubenda-tp-btn,
    #usercentrics-root, .uc-banner, .uc-overlay,
    #termly-consent-banner, [data-testid="termly-consent-banner"],
    #_evidon-banner, .evidon-banner-message, ._evidon-banner-message,
    .ch2, .ch2-dialog, .ch2-style-light,
    #_sp_message_container, #sp_message_container, .sp_message_iframe,
    #cookie-consent, #cookieConsent, .cookie-consent, .cookieConsent,
    #cookie-notice, .cookie-notice, .cookie-banner,
    #gdpr, .gdpr-banner, .gdpr-modal,
    [id*="cookie-banner"], [class*="cookie-consent-banner"],
    [aria-label*="cookie consent" i][role="dialog"],
    [aria-label*="cookie notice" i][role="dialog"]
    {
      display: none !important;
      visibility: hidden !important;
    }
    /* Restore scroll/pointer events that some CMPs lock on body. */
    html.didomi-popup-open, body.didomi-popup-open,
    html.qc-cmp2-noscroll, body.qc-cmp2-noscroll,
    html.cky-consent-bar-active, body.cky-consent-bar-active,
    body.modal-open[data-cookie-consent],
    html.uc-blocked, body.uc-blocked
    {
      overflow: auto !important;
      pointer-events: auto !important;
    }
    """

    /// Click-based consent handler. Defines `window.__mcpConsent.run(action)`
    /// where `action` is one of `accept_all` | `decline_all` |
    /// `decline_optional`. Each rule has a detection selector and one
    /// or more click selectors per action; the first match wins. Re-runs
    /// up to a few times to catch banners that inject after page load.
    static let consentJS = """
    (function(){
      if (window.__mcpConsent) return;

      function $(sel, root){ return (root||document).querySelector(sel); }
      function clickFirst(sels){
        if (!sels) return false;
        const list = Array.isArray(sels) ? sels : [sels];
        for (const s of list) {
          const el = $(s);
          if (el && el.offsetParent !== null) {
            try { el.click(); return true; } catch(_) {}
          }
        }
        return false;
      }

      // Rule schema:
      //   detect:        CSS selector(s) — at least one must match
      //   acceptAll:     selector(s) for the affirmative button
      //   declineAll:    selector(s) for full reject
      //   declineOpt:    selector(s) for "necessary only" if separate
      //                  (falls back to declineAll when missing)
      const RULES = [
        { name: 'OneTrust',
          detect: '#onetrust-banner-sdk, #onetrust-consent-sdk',
          acceptAll: '#onetrust-accept-btn-handler',
          declineAll: '#onetrust-reject-all-handler, .ot-pc-refuse-all-handler' },
        { name: 'Cookiebot',
          detect: '#CybotCookiebotDialog',
          acceptAll: '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll, #CybotCookiebotDialogBodyButtonAccept',
          declineAll: '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll, #CybotCookiebotDialogBodyButtonDecline' },
        { name: 'Didomi',
          detect: '#didomi-host, #didomi-popup',
          acceptAll: '#didomi-notice-agree-button',
          declineAll: '#didomi-notice-disagree-button' },
        { name: 'Quantcast',
          detect: '.qc-cmp2-container',
          acceptAll: '.qc-cmp2-summary-buttons button[mode="primary"]',
          declineAll: '.qc-cmp2-summary-buttons button[mode="secondary"]' },
        { name: 'TrustArc',
          detect: '#truste-consent-track, .trustarc-banner-overlay',
          acceptAll: '.call, #truste-consent-button',
          declineAll: '#truste-consent-required' },
        { name: 'CookieYes',
          detect: '#cookie-law-info-bar, .cky-modal',
          acceptAll: '#wt-cli-accept-all-btn, .cky-btn-accept',
          declineAll: '#wt-cli-reject-all-btn, .cky-btn-reject' },
        { name: 'Klaro',
          detect: '.klaro',
          acceptAll: '.cm-btn-accept-all',
          declineAll: '.cm-btn-decline' },
        { name: 'Iubenda',
          detect: '#iubenda-cs-banner',
          acceptAll: '.iubenda-cs-accept-btn',
          declineAll: '.iubenda-cs-reject-btn' },
        { name: 'Usercentrics',
          detect: '#usercentrics-root, .uc-banner',
          acceptAll: '[data-testid="uc-accept-all-button"]',
          declineAll: '[data-testid="uc-deny-all-button"]' },
        { name: 'Termly',
          detect: '#termly-consent-banner',
          acceptAll: '[t-accept-all], button[data-tid="banner-accept"]',
          declineAll: '[t-decline-all], button[data-tid="banner-decline"]' },
        { name: 'Sourcepoint',
          detect: '#_sp_message_container, .sp_message_iframe',
          acceptAll: 'button[title*="Accept" i]',
          declineAll: 'button[title*="Reject" i], button[title*="Decline" i]' },
      ];

      // Generic text-based fallback — case-insensitive match against
      // visible text content of buttons & links. Last resort when no
      // vendor rule fires.
      const TEXT_PATTERNS = {
        accept_all:       [/accept all/i, /allow all/i, /^i agree$/i, /^agree$/i, /^accept$/i, /^ok$/i, /^got it$/i],
        decline_all:      [/reject all/i, /decline all/i, /refuse all/i, /^reject$/i, /^decline$/i, /deny all/i, /^disagree$/i],
        decline_optional: [/only necessary/i, /reject non[- ]essential/i, /strictly necessary/i,
                           /essential only/i, /necessary only/i, /reject optional/i,
                           /reject all/i, /decline all/i],
      };
      function clickByText(action){
        const patterns = TEXT_PATTERNS[action] || [];
        const buttons = document.querySelectorAll('button, [role="button"], a.button, a.btn, input[type="button"], input[type="submit"]');
        for (const btn of buttons) {
          if (btn.offsetParent === null) continue;
          const txt = (btn.innerText || btn.value || '').trim();
          if (!txt) continue;
          for (const p of patterns) {
            if (p.test(txt)) {
              try { btn.click(); return txt.slice(0, 80); } catch(_) {}
            }
          }
        }
        return null;
      }

      function tryOnce(action){
        for (const rule of RULES) {
          if (!$(rule.detect)) continue;
          let acted = false;
          if (action === 'accept_all') acted = clickFirst(rule.acceptAll);
          else if (action === 'decline_all') acted = clickFirst(rule.declineAll);
          else if (action === 'decline_optional') {
            acted = clickFirst(rule.declineOpt) || clickFirst(rule.declineAll);
          }
          if (acted) return { vendor: rule.name, source: 'rule' };
        }
        const matched = clickByText(action);
        if (matched) return { vendor: 'generic', source: 'text', match: matched };
        return null;
      }

      window.__mcpConsent = {
        // Run up to N times across a short window. Banners often inject
        // 100-1000ms after navigation finishes (lazy script, hydration).
        run(action){
          if (action === 'none') return null;
          let result = tryOnce(action);
          if (result) return result;
          let tries = 0;
          const interval = setInterval(() => {
            tries += 1;
            const r = tryOnce(action);
            if (r || tries >= 20) clearInterval(interval);
          }, 250);
          return null;
        }
      };
    })();
    """
}
