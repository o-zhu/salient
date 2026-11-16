(function () {
  var overlayId = "uworld-tts-highlight-overlay";

  function nodeFromTextNodePath(textNodePath) {
    if (!textNodePath) return null;
    var node = document.body;
    var parts = String(textNodePath).split(".");
    for (var i = 0; i < parts.length; i += 1) {
      var index = Number(parts[i]);
      if (!node || !node.childNodes || !Number.isFinite(index)) return null;
      node = node.childNodes[index];
    }
    return node && node.nodeType === Node.TEXT_NODE ? node : null;
  }

  function rangeFromPayload(payload) {
    var node = nodeFromTextNodePath(payload.textNodePath);
    if (!node) return null;
    var start = Math.max(0, Math.min(node.textContent.length, Number(payload.startOffset || 0)));
    var end = Math.max(start, Math.min(node.textContent.length, Number(payload.endOffset || node.textContent.length)));
    var range = document.createRange();
    range.setStart(node, start);
    range.setEnd(node, end);
    return range;
  }

  function nearestScrollable(element) {
    var current = element;
    while (current && current !== document.body && current !== document.documentElement) {
      var style = window.getComputedStyle(current);
      var overflow = (style.overflowY || "") + " " + (style.overflow || "");
      if (/(auto|scroll|overlay)/.test(overflow) && current.scrollHeight > current.clientHeight) {
        return current;
      }
      current = current.parentElement;
    }
    return null;
  }

  function scrollRangeIntoView(range) {
    if (!range) return;
    var element = range.startContainer.parentElement;
    var scroller = nearestScrollable(element);
    var rect = range.getBoundingClientRect();
    if (scroller) {
      var containerRect = scroller.getBoundingClientRect();
      var margin = 36;
      if (rect.top < containerRect.top + margin) {
        scroller.scrollTop += rect.top - containerRect.top - margin;
      } else if (rect.bottom > containerRect.bottom - margin) {
        scroller.scrollTop += rect.bottom - containerRect.bottom + margin;
      }
    } else if (element && element.scrollIntoView) {
      element.scrollIntoView({ block: "center", inline: "nearest" });
    }
  }

  function visibleRectsForRange(range) {
    if (!range) return [];
    return Array.from(range.getClientRects())
      .filter(function (rect) {
        return rect.width > 0 && rect.height > 0 &&
          rect.bottom >= 0 && rect.right >= 0 &&
          rect.top <= window.innerHeight && rect.left <= window.innerWidth;
      })
      .map(function (rect) {
        return {
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height
        };
      });
  }

  window.__uworldTTSClearHighlight = function __uworldTTSClearHighlight() {
    var existing = document.getElementById(overlayId);
    if (existing) existing.remove();
  };

  window.__uworldTTSHighlight = function __uworldTTSHighlight(payload) {
    window.__uworldTTSClearHighlight();
    var range = rangeFromPayload(payload || {});
    scrollRangeIntoView(range);
    var rects = visibleRectsForRange(range);
    if (!rects.length) rects = payload.rects || [];

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
