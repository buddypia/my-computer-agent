import Foundation

/// JavaScript run inside the page through `Runtime.callFunctionOn`, with the
/// target element bound to `this`.
///
/// Each function is
/// dependency-free and swallows its own exceptions, returning a small
/// JSON-serialisable value the Swift side interprets. Keeping them as strings
/// rather than building expressions ad hoc means the same code runs on every
/// call and can be reviewed in one place.
public enum PageScripts {
    /// Mirrors Playwright's `fill` semantics. Returns `{status: "done"}` when
    /// the value was set natively (date/range/colour inputs), `{status:
    /// "needsinput", value}` when the caller should focus + insert text, or
    /// `{status: "error", reason}`.
    public static let fillElementValue = """
        function(rawValue) {
          const setValueTypes = new Set(["color","date","datetime-local","month","range","time","week"]);
          const typeIntoTypes = new Set(["","email","number","password","search","tel","text","url"]);
          const element = this;
          if (!element.isConnected) return { status: "error", reason: "notconnected" };
          const doc = element.ownerDocument || document;
          const win = doc.defaultView || window;
          const fire = (value) => {
            let inputEvent;
            try { inputEvent = new win.InputEvent("input", { bubbles: true, composed: true, data: value, inputType: "insertText" }); }
            catch (e) { inputEvent = new win.Event("input", { bubbles: true, composed: true }); }
            element.dispatchEvent(inputEvent);
            element.dispatchEvent(new win.Event("change", { bubbles: true }));
          };
          try {
            if (element instanceof win.HTMLInputElement) {
              const type = (element.type || "").toLowerCase();
              if (!typeIntoTypes.has(type) && !setValueTypes.has(type)) return { status: "error", reason: "unsupported-input-type:" + type };
              let value = rawValue;
              if (type === "number") {
                const trimmed = rawValue.trim();
                if (trimmed !== "" && Number.isNaN(Number(trimmed))) return { status: "error", reason: "invalid-number-value" };
                value = trimmed;
              }
              if (setValueTypes.has(type)) {
                const trimmed = rawValue.trim();
                try { element.focus(); } catch (e) {}
                const setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, "value")?.set;
                if (typeof setter === "function") setter.call(element, trimmed); else element.value = trimmed;
                if (element._valueTracker && element._valueTracker.setValue) element._valueTracker.setValue(trimmed);
                if (element.value !== trimmed) return { status: "error", reason: "malformed-value" };
                fire(trimmed);
                return { status: "done" };
              }
              return { status: "needsinput", value };
            }
            if (element instanceof win.HTMLTextAreaElement) return { status: "needsinput", value: rawValue };
            if (element instanceof win.HTMLSelectElement) return { status: "error", reason: "unsupported-element:select" };
            if (element.isContentEditable) return { status: "needsinput", value: rawValue };
            return { status: "error", reason: "unsupported-element" };
          } catch (error) {
            return { status: "needsinput", value: rawValue, reason: "exception:" + (error && error.message) };
          }
        }
        """

    /// Focuses the element and selects its current contents so the next
    /// `Input.insertText` replaces rather than appends. Returns true when the
    /// element is a text control it could prepare.
    public static let prepareElementForTyping = """
        function() {
          try {
            const element = this;
            if (!element.isConnected) return false;
            const doc = element.ownerDocument || document;
            const win = doc.defaultView || window;
            try { element.focus(); } catch (e) {}
            if (element instanceof win.HTMLInputElement || element instanceof win.HTMLTextAreaElement) {
              try { element.select(); return true; } catch (e) {}
              try { element.setSelectionRange(0, (element.value || "").length); return true; } catch (e) {}
              return true;
            }
            if (element.isContentEditable) {
              const selection = doc.getSelection && doc.getSelection();
              const range = doc.createRange && doc.createRange();
              if (selection && range) {
                try { range.selectNodeContents(element); selection.removeAllRanges(); selection.addRange(range); } catch (e) {}
              }
              return true;
            }
            return false;
          } catch (e) { return false; }
        }
        """

    public static let focusElement = """
        function() { try { if (typeof this.focus === "function") this.focus(); } catch (e) {} }
        """

    /// Scrolls the element (or the window when `this` is html/body) to a
    /// percentage of its scroll range.
    public static let scrollElementToPercent = """
        function(percent) {
          const normalize = (v) => {
            if (typeof v === "number" && Number.isFinite(v)) return v;
            const n = parseFloat(String(v ?? "").replace("%", ""));
            return Number.isFinite(n) ? n : 0;
          };
          try {
            const pct = Math.max(0, Math.min(normalize(percent), 100));
            const element = this;
            const tag = (element.tagName || "").toLowerCase();
            if (tag === "html" || tag === "body") {
              const doc = element.ownerDocument || document;
              const win = doc.defaultView || window;
              const root = doc.scrollingElement || doc.documentElement || doc.body;
              const maxTop = Math.max(0, (root.scrollHeight || 0) - win.innerHeight);
              win.scrollTo({ top: maxTop * (pct / 100), left: win.scrollX || 0, behavior: "smooth" });
              return true;
            }
            const maxTop = Math.max(0, (element.scrollHeight || 0) - (element.clientHeight || 0));
            element.scrollTo({ top: maxTop * (pct / 100), left: element.scrollLeft || 0, behavior: "smooth" });
            return true;
          } catch (e) { return false; }
        }
        """

    /// Scrolls by one viewport (or one element height) in `dir` (+1/-1) and
    /// resolves once the scroll position stops changing.
    public static let scrollByChunk = """
        function(dir) {
          const waitForScrollEnd = (el) => new Promise((resolve) => {
            let last = el.scrollTop ?? 0;
            let stableFrames = 0;
            const check = () => {
              const cur = el.scrollTop ?? 0;
              if (cur === last) { if (++stableFrames >= 3) return resolve(); }
              else stableFrames = 0;
              last = cur;
              requestAnimationFrame(check);
            };
            requestAnimationFrame(check);
          });
          const tag = (this.tagName || "").toLowerCase();
          if (tag === "html" || tag === "body") {
            const h = window.visualViewport ? window.visualViewport.height : window.innerHeight;
            window.scrollBy({ top: h * dir, left: 0, behavior: "smooth" });
            return waitForScrollEnd(document.scrollingElement || document.documentElement);
          }
          const h = this.getBoundingClientRect().height;
          this.scrollBy({ top: h * dir, left: 0, behavior: "smooth" });
          return waitForScrollEnd(this);
        }
        """

    /// Selects `<option>`s by label or value on a `<select>` and fires the
    /// input/change events frameworks listen for. Returns selected values.
    public static let selectElementOptions = """
        function(rawValues) {
          try {
            if (!(this instanceof HTMLSelectElement)) return [];
            const desired = Array.isArray(rawValues) ? rawValues : [rawValues];
            const wanted = new Set(desired.map((v) => String(v ?? "").trim()));
            const matches = (option) => {
              const label = (option.label || option.textContent || "").trim();
              const value = String(option.value ?? "").trim();
              return wanted.has(label) || wanted.has(value);
            };
            if (this.multiple) {
              for (const option of Array.from(this.options)) option.selected = matches(option);
            } else {
              let chosen = false;
              for (const option of Array.from(this.options)) {
                if (!chosen && matches(option)) { option.selected = true; this.value = option.value; chosen = true; }
                else option.selected = false;
              }
            }
            this.dispatchEvent(new Event("input", { bubbles: true }));
            this.dispatchEvent(new Event("change", { bubbles: true }));
            return Array.from(this.selectedOptions).map((o) => o.value);
          } catch (e) { return []; }
        }
        """

    public static let isElementVisible = """
        function() {
          try {
            const element = this;
            if (!element.isConnected) return false;
            const style = (element.ownerDocument?.defaultView || window).getComputedStyle(element);
            if (!style || style.display === "none" || style.visibility === "hidden") return false;
            const opacity = parseFloat(style.opacity ?? "1");
            if (!Number.isFinite(opacity) || opacity === 0) return false;
            const rect = element.getBoundingClientRect();
            if (!rect || Math.max(rect.width, rect.height) === 0) return false;
            return element.getClientRects().length > 0;
          } catch (e) { return false; }
        }
        """

    public static let readInnerText = """
        function() {
          try {
            const inner = this.innerText;
            if (typeof inner === "string" && inner.length > 0) return inner;
            return typeof this.textContent === "string" ? this.textContent : "";
          } catch (e) { return ""; }
        }
        """

    public static let readInputValue = """
        function() {
          try {
            const tag = (this.tagName || "").toLowerCase();
            if (tag === "input" || tag === "textarea" || tag === "select") return String(this.value ?? "");
            if (this.isContentEditable) return String(this.textContent ?? "");
            return "";
          } catch (e) { return ""; }
        }
        """

    /// Dispatches a synthetic click on the element itself, for the rare
    /// element whose hit-test target is covered by an overlay.
    public static let dispatchDomClick = """
        function() {
          try {
            this.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, composed: true, view: this.ownerDocument?.defaultView || window }));
          } catch (e) { try { this.click(); } catch (_) {} }
        }
        """

    /// Page-level expression: visible text of the document body, trimmed.
    public static let documentText = """
        (() => { try { return (document.body && document.body.innerText) || document.documentElement.textContent || ""; } catch (e) { return ""; } })()
        """

    /// Page-level expression: readiness + URL + title in one round trip.
    public static let pageState = """
        (() => ({ readyState: document.readyState, url: location.href, title: document.title }))()
        """
}
