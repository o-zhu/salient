import Foundation

public enum HighlightJavaScript {
    public static func build(segment: CapturedSegment) -> String {
        let payload = payloadLiteral(for: segment)
        return """
        (function () {
        \(highlightSource)
          window.__uworldTTSHighlight(\(payload));
          return "highlighted";
        })()
        """
    }

    public static func clear() -> String {
        """
        (function () {
        \(highlightSource)
          window.__uworldTTSClearHighlight();
          return "cleared";
        })()
        """
    }

    private static func payloadLiteral(for segment: CapturedSegment) -> String {
        guard let data = try? JSONEncoder().encode(segment),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static var highlightSource: String {
        guard let url = Bundle.module.url(forResource: "safari_highlight", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return fallbackHighlightSource
        }
        return source
    }

    private static let fallbackHighlightSource = """
    (function () {
      var overlayId = "uworld-tts-highlight-overlay";
      window.__uworldTTSClearHighlight = function __uworldTTSClearHighlight() {
        var existing = document.getElementById(overlayId);
        if (existing) existing.remove();
      };
      window.__uworldTTSHighlight = function __uworldTTSHighlight(payload) {
        window.__uworldTTSClearHighlight();
        var rects = payload.rects || (payload.rect ? [payload.rect] : []);
        var overlay = document.createElement("div");
        overlay.id = overlayId;
        overlay.setAttribute("data-segment-id", payload.id || "");
        overlay.style.position = "fixed";
        overlay.style.inset = "0";
        overlay.style.pointerEvents = "none";
        overlay.style.zIndex = "2147483647";
        rects.forEach(function (rect) {
          var mark = document.createElement("div");
          mark.style.position = "absolute";
          mark.style.left = Math.max(0, rect.x - 3) + "px";
          mark.style.top = Math.max(0, rect.y - 2) + "px";
          mark.style.width = Math.max(1, rect.width + 6) + "px";
          mark.style.height = Math.max(1, rect.height + 4) + "px";
          mark.style.borderRadius = "4px";
          mark.style.background = "rgba(255, 230, 80, 0.42)";
          mark.style.boxShadow = "0 0 0 1px rgba(122, 85, 0, 0.25)";
          overlay.appendChild(mark);
        });
        document.documentElement.appendChild(overlay);
      };
    })();
    """
}
