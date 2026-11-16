import Foundation

public enum CaptureJavaScript {
    public static func build(mode: CaptureMode) -> String {
        if let source = bundledCaptureSource {
            return """
            (function () {
            \(source)
              return JSON.stringify(window.captureUWorldSegments(\(javaScriptStringLiteral(mode.rawValue))));
            })()
            """
        }

        return fallbackCaptureScript(mode: mode)
    }

    private static var bundledCaptureSource: String? {
        guard let url = Bundle.module.url(forResource: "safari_capture", withExtension: "js") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func fallbackCaptureScript(mode: CaptureMode) -> String {
        """
        (function () {
          function cleanText(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
          }

          function isVisible(el) {
            var style = getComputedStyle(el);
            var rect = el.getBoundingClientRect();
            return style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          }

          function roleFor(text, el) {
            var lower = text.toLowerCase();
            if (/^suggested\\s+highlights$/i.test(text)) return 'ui';
            var ancestor = el;
            for (var depth = 0; ancestor && ancestor !== document.body && depth < 4; depth += 1) {
              if (/^suggested\\s+highlights$/i.test(cleanText(ancestor.textContent))) return 'ui';
              ancestor = ancestor.parentElement;
            }
            if (/^(previous|next|back|continue|submit|review|mark|pause|resume|calculator|notes)$/i.test(text)) return 'ui';
            if (/^[A-Z]\\./.test(text)) return 'choice';
            if (/\\?$/.test(text) || /which|what|most likely|next best/i.test(text)) return 'question';
            if (lower.indexOf('explanation') >= 0 || lower.indexOf('objective') >= 0) return 'explanation';
            return 'stem';
          }

          function regionFor(rect) {
            if (rect.left >= innerWidth * 0.50) return 'right';
            if (rect.right <= innerWidth * 0.50) return 'left';
            return 'center';
          }

          function captureUWorldSegments(readMode) {
            var nodes = Array.from(document.querySelectorAll('p, li, button, [role=button], h1, h2, h3, h4, div, span'))
              .filter(isVisible)
              .map(function (el, index) {
                var text = cleanText(el.innerText || el.textContent || el.value || el.getAttribute('aria-label'));
                var rect = el.getBoundingClientRect();
                return {
                  id: 'segment-' + index,
                  text: text,
                  role: roleFor(text, el),
                  region: regionFor(rect),
                  rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
                };
              })
              .filter(function (segment) {
                return segment.text.length > 0 && segment.text.length < 1200;
              });
            return { mode: readMode, segments: nodes };
          }

          window.captureUWorldSegments = captureUWorldSegments;
          return JSON.stringify(captureUWorldSegments('\(mode.rawValue)'));
        })()
        """
    }
}
