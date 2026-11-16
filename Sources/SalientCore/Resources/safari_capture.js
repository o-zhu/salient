(function () {
  function rectsForRange(range) {
    return Array.from(range.getClientRects())
      .filter(function (rect) {
        return rect.width > 0 && rect.height > 0;
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

  function domPathForNode(node) {
    var parts = [];
    var current = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    while (current && current.nodeType === Node.ELEMENT_NODE && parts.length < 8) {
      var index = 1;
      var sibling = current;
      while ((sibling = sibling.previousElementSibling)) {
        if (sibling.tagName === current.tagName) index += 1;
      }
      parts.unshift(current.tagName.toLowerCase() + ":nth-of-type(" + index + ")");
      current = current.parentElement;
    }
    return parts.join(" > ");
  }

  function textNodePathForNode(node) {
    var parts = [];
    var current = node;
    while (current && current !== document.body) {
      var parent = current.parentNode;
      if (!parent) break;
      parts.unshift(Array.prototype.indexOf.call(parent.childNodes, current));
      current = parent;
    }
    return parts.join(".");
  }

  function splitTextIntoChunks(text) {
    var chunks = [];
    var start = 0;
    for (var index = 0; index < text.length; index += 1) {
      if (!isSentenceBoundary(text, index)) continue;
      pushChunk(chunks, text, start, index + 1);
      start = index + 1;
    }
    pushChunk(chunks, text, start, text.length);
    return chunks;
  }

  function isSentenceBoundary(text, index) {
    var char = text.charAt(index);
    if (!/[.!?;:\n]/.test(char)) return false;
    if (char === "." && /\d/.test(text.charAt(index - 1)) && /\d/.test(text.charAt(index + 1))) {
      return false;
    }
    return true;
  }

  function pushChunk(chunks, text, start, end) {
    var raw = text.slice(start, end);
    var value = raw.replace(/\s+/g, " ").trim();
    if (value.length >= 2) {
      chunks.push({
        text: value,
        start: start,
        end: end
      });
    }
  }

  function classifyRegion(rects) {
    if (!rects.length) return "unknown";
    var mid = rects.reduce(function (sum, rect) {
      return sum + rect.x + rect.width / 2;
    }, 0) / rects.length;
    if (mid >= window.innerWidth * 0.54) return "right";
    if (mid <= window.innerWidth * 0.58) return "left";
    return "unknown";
  }

  function normalizedText(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
  }

  function clippedText(value, limit) {
    var text = normalizedText(value);
    if (text.length <= limit) return text;
    return text.slice(0, limit).trim();
  }

  function rectsForElement(element) {
    if (!element || !element.getClientRects) return [];
    return Array.from(element.getClientRects())
      .filter(function (rect) {
        return rect.width > 0 && rect.height > 0;
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

  function elementIsVisible(element) {
    if (!element || !element.getClientRects || !element.getClientRects().length) return false;
    var style = window.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) {
      return false;
    }
    return true;
  }

  function firstRect(rects) {
    return rects && rects.length ? rects[0] : { x: 0, y: 0, width: 0, height: 0 };
  }

  function answerLabelFromText(text) {
    var compact = normalizedText(text);
    var match = /(?:^|\s|\()([A-J])(?:[\).]|\s*[:\-])(?:\s|$)/i.exec(compact);
    return match ? match[1].toUpperCase() : null;
  }

  function answerStateForElement(element, text, contextText) {
    var candidate = element && element.closest && element.closest(
      "[aria-checked], [aria-selected], [data-correct], [data-selected], " +
      "[class*='answer'], [class*='choice'], [class*='option'], li, label, [role='option']"
    );
    candidate = candidate || element;
    var signatureParts = [
      text || "",
      contextText || "",
      candidate && candidate.id || "",
      candidate && candidate.className || "",
      candidate && candidate.getAttribute ? candidate.getAttribute("aria-label") || "" : "",
      candidate && candidate.getAttribute ? candidate.getAttribute("title") || "" : "",
      candidate && candidate.getAttribute ? candidate.getAttribute("data-correct") || "" : "",
      candidate && candidate.getAttribute ? candidate.getAttribute("data-selected") || "" : ""
    ];
    var signature = signatureParts.join(" ").toLowerCase();
    var selected = /\b(selected|your answer|chosen|checked|aria-checked\s*true|aria-selected\s*true|data-selected\s*true|highlighted)\b/.test(signature) ||
      /[✕✖×❌]/.test(signature) ||
      /\bred\s*x\b/.test(signature);
    var correct = !selected && (
      /\b(correct answer|correct|keyed|data-correct\s*true|answer-correct|green check)\b/.test(signature) ||
      /[✓✔✅☑]/.test(signature)
    );
    return {
      answerLabel: answerLabelFromText(contextText) || answerLabelFromText(text),
      isSelected: selected,
      isCorrect: correct
    };
  }

  function tableCellPayload(cell) {
    var rects = rectsForElement(cell);
    return {
      text: clippedText(cell.textContent, 500),
      rowSpan: parseInt(cell.getAttribute("rowspan") || "1", 10) || 1,
      columnSpan: parseInt(cell.getAttribute("colspan") || "1", 10) || 1,
      isHeader: cell.tagName.toLowerCase() === "th",
      rect: firstRect(rects)
    };
  }

  function captureTables() {
    return Array.from(document.querySelectorAll("table")).map(function (table, index) {
      if (!elementIsVisible(table)) return null;
      var rects = rectsForElement(table);
      if (!rects.length) return null;
      var rowPayloads = Array.from(table.querySelectorAll("tr")).map(function (row) {
        return Array.from(row.children)
          .filter(function (cell) {
            return /^(td|th)$/i.test(cell.tagName || "");
          })
          .map(tableCellPayload)
          .filter(function (cell) {
            return cell.text.length > 0;
          });
      }).filter(function (row) {
        return row.length > 0;
      });
      if (!rowPayloads.length) return null;
      var firstRowIsHeader = rowPayloads[0].some(function (cell) {
        return cell.isHeader;
      });
      var headers = firstRowIsHeader ? rowPayloads[0].map(function (cell) { return cell.text; }) : [];
      var dataRows = (firstRowIsHeader ? rowPayloads.slice(1) : rowPayloads).map(function (row) {
        return row.map(function (cell) { return cell.text; });
      });
      var captionElement = table.querySelector("caption");
      return {
        id: "table-" + index,
        caption: captionElement ? clippedText(captionElement.textContent, 240) : null,
        headers: headers,
        rows: dataRows,
        cells: rowPayloads,
        region: classifyRegion(rects),
        role: table.getAttribute("role") || "table",
        rect: firstRect(rects),
        rects: rects,
        domPath: domPathForNode(table)
      };
    }).filter(Boolean);
  }

  function nearbyTextForMedia(element) {
    var values = [];
    if (element.previousElementSibling) values.push(element.previousElementSibling.textContent);
    if (element.nextElementSibling) values.push(element.nextElementSibling.textContent);
    if (element.parentElement) values.push(element.parentElement.getAttribute("aria-label"));
    return clippedText(values.filter(Boolean).join(" "), 240);
  }

  function mediaCaption(element) {
    if (!element) return "";
    if (element.matches && element.matches("figure")) {
      var figcaption = element.querySelector("figcaption");
      return figcaption ? clippedText(figcaption.textContent, 240) : "";
    }
    if (element.closest && element.closest("figure")) {
      var parentCaption = element.closest("figure").querySelector("figcaption");
      return parentCaption ? clippedText(parentCaption.textContent, 240) : "";
    }
    var title = element.querySelector && element.querySelector("title");
    return clippedText(
      element.getAttribute("aria-label") ||
      element.getAttribute("title") ||
      (title ? title.textContent : ""),
      240
    );
  }

  function captureMediaReferences() {
    return Array.from(document.querySelectorAll("figure, img, svg, canvas")).map(function (element, index) {
      if (!elementIsVisible(element)) return null;
      if (element.closest && element.closest("table")) return null;
      var tag = element.tagName.toLowerCase();
      if (tag !== "figure" && element.closest && element.closest("figure")) return null;
      var rects = rectsForElement(element);
      if (!rects.length) return null;
      return {
        id: "media-" + index,
        kind: tag,
        altText: clippedText(element.getAttribute("alt") || "", 240),
        caption: mediaCaption(element),
        nearbyText: nearbyTextForMedia(element),
        role: element.getAttribute("role") || null,
        region: classifyRegion(rects),
        rect: firstRect(rects),
        rects: rects,
        domPath: domPathForNode(element)
      };
    }).filter(Boolean);
  }

  function hasControlAncestor(element) {
    if (!element) return false;
    var control = element.closest && element.closest(
      "button, input, select, textarea, summary, nav, menu, " +
      "[role='button'], [role='link'], [role='menu'], [role='menubar'], " +
      "[role='menuitem'], [role='navigation'], [role='tab'], [role='toolbar'], " +
      "[aria-haspopup], [aria-controls]"
    );
    if (control) return true;

    var current = element;
    var depth = 0;
    while (current && current !== document.body && depth < 5) {
      var signature = [
        current.id || "",
        current.className || "",
        current.getAttribute ? current.getAttribute("aria-label") || "" : "",
        current.getAttribute ? current.getAttribute("data-testid") || "" : ""
      ].join(" ").toLowerCase();
      if (/\b(nav|navbar|toolbar|footer|header|pagination|pager|button|control|menu|modal|dialog)\b/.test(signature)) {
        return true;
      }
      current = current.parentElement;
      depth += 1;
    }
    return false;
  }

  function isLikelyUnitText(text) {
    var compact = text.replace(/\s+/g, " ").trim();
    if (!compact) return false;

    var micro = "[µμu]";
    var squared = "(?:\\^\\s*2|2|²)";
    var cubed = "(?:\\^\\s*3|3|³)";
    var microgram = "(?:mcg|" + micro + "g)";
    var massUnit = "(?:" + microgram + "|mg|g|ng|pg)";
    var activityUnit = "(?:m?IU|" + micro + "U|U|units?)";
    var perBodyUnit = "(?:" + massUnit + "|" + activityUnit + "|mL|L|kg)";
    var unitPatterns = [
      "mm\\s*hg",
      "mm\\s*H[₂2]O",
      "cm\\s*H[₂2]O",
      "(?:" + massUnit + "|" + activityUnit + ")\\s*/\\s*(?:dL|mL|L)",
      "mEq\\s*/\\s*L",
      "m?mol\\s*/\\s*L",
      "m?Osm(?:ol)?\\s*/\\s*(?:kg|L)(?:\\s*H[₂2]O)?",
      "m?mol",
      "m?Osm(?:ol)?",
      perBodyUnit + "\\s*/\\s*(?:m\\s*" + squared + "|24\\s*(?:h|hr|hrs?|hours?)|min|kg|day|cell)",
      "Hb\\s*/\\s*cell",
      "(?:cells?|million|thousand|k)\\s*/\\s*(?:mm(?:\\s*" + cubed + ")?|" + micro + "L|mcL)",
      "/\\s*(?:mm(?:\\s*" + cubed + ")?|" + micro + "L|mcL)",
      "/\\s*min",
      "/\\s*m(?:\\s*" + squared + ")?",
      "mm\\s*/\\s*(?:h|hr|hrs?|hours?)",
      "/\\s*24\\s*(?:h|hr|hrs?|hours?)",
      micro + "m\\s*" + cubed,
      "fL",
      "(?:mL|mcL|" + micro + "L|L)",
      "kg",
      "m\\s*" + squared,
      "cm",
      "mm",
      "seconds?|secs?|s"
    ];
    return new RegExp("^(?:" + unitPatterns.join("|") + ")$", "i").test(compact);
  }

  function isLikelyInterfaceText(text, element) {
    var compact = text.replace(/\s+/g, " ").trim();
    if (!compact) return true;
    // UWorld renders this checkbox label inside the question pane. Inspect the
    // small label's ancestors as well, since its words can be separate spans.
    // Exact matches preserve prose that happens to discuss suggested highlights.
    if (/^suggested\s+highlights$/i.test(compact)) return true;
    var highlightLabel = element;
    for (var depth = 0; highlightLabel && highlightLabel !== document.body && depth < 4; depth += 1) {
      var labelText = String(highlightLabel.textContent || "").replace(/\s+/g, " ").trim();
      if (/^suggested\s+highlights$/i.test(labelText)) return true;
      highlightLabel = highlightLabel.parentElement;
    }
    if (/^item\s+\d+\s+of\s+\d+$/i.test(compact)) return true;
    if (/^question\s+id\s*:?\s*[\w-]*$/i.test(compact)) return true;
    if (/^question\s+status(?:\s+\d+)*$/i.test(compact)) return true;
    if (/^mark\s+question$/i.test(compact)) return true;
    if (/^\d+\s*\/\s*\d+$/.test(compact)) return true;
    if (/^(?:a\s*){2,3}$/i.test(compact)) return true;
    if (/^(previous|next|back|continue|submit|review|mark|pause|resume|tutorial|uask|full screen|calculator|lab values|notes|reverse color|text zoom|settings)$/i.test(compact)) return true;
    if (/^(medical library|my notebook|flashcards|feedback|suspend|end block)$/i.test(compact)) return true;
    if (/^block\s+time\s+elapsed\s*:\s*\d{1,2}:\d{2}(?::\d{2})?$/i.test(compact)) return true;
    if (/^(?:\d+\s*%\s*)?answered\s+correctly$/i.test(compact)) return true;
    if (/^\d+\s+secs?\s+time\s+spent$/i.test(compact)) return true;
    if (/^display\s+a\s+menu$/i.test(compact)) return true;
    if (/^correct$/i.test(compact)) return true;
    if (isLikelyUnitText(compact)) return true;
    if (/^\d{1,2}:\d{2}(?::\d{2})?$/.test(compact)) return true;
    if (/^(?:\d+\s*)?(?:flag|notes?|feedback|settings|search|filter)$/i.test(compact)) return true;
    if (hasControlAncestor(element) && compact.length <= 40) return true;
    return false;
  }

  function rectIntersectsViewport(rect, viewportHeight) {
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    var top = typeof rect.top === "number" ? rect.top : rect.y;
    var bottom = typeof rect.bottom === "number" ? rect.bottom : top + rect.height;
    return bottom >= 0 && top <= viewportHeight;
  }

  function isLikelyInterfacePosition(text, rects) {
    if (!rects || !rects.length) return false;
    var compact = text.replace(/\s+/g, " ").trim();
    if (!compact || compact.length > 80) return false;
    var viewportHeight = window.innerHeight;
    var viewportRects = rects.filter(function (rect) {
      return rectIntersectsViewport(rect, viewportHeight);
    });
    if (!viewportRects.length) return false;
    var avgX = viewportRects.reduce(function (sum, rect) {
      return sum + rect.x + rect.width / 2;
    }, 0) / viewportRects.length;
    var avgY = viewportRects.reduce(function (sum, rect) {
      return sum + rect.y + rect.height / 2;
    }, 0) / viewportRects.length;
    if (avgY < 64) return true;
    if (avgY > viewportHeight - 72) return true;
    if (avgX < 112 && compact.length <= 40) return true;
    return false;
  }

  function isAnswerChoiceText(text, fullText, startOffset, contextText) {
    var compact = text.trim().toLowerCase();
    var full = (fullText || text).trim().toLowerCase();
    var context = (contextText || "").trim().toLowerCase();
    return hasAnswerChoiceLabel(compact) ||
      hasAnswerChoiceLabel(full) ||
      hasAnswerChoiceLabel(context) ||
      isInsideAnswerChoiceRun(fullText || text, startOffset);
  }

  function hasAnswerChoiceLabel(text) {
    var compact = text.trim().toLowerCase().replace(/^[\"'“”‘’]\s*/, "");
    return /^[a-j][.)](?:\s+|$)/.test(compact) ||
      /^[(][a-j][)](?:\s+|$)/.test(compact);
  }

  function isInsideAnswerChoiceRun(fullText, startOffset) {
    if (typeof startOffset !== "number" || !isFinite(startOffset)) return false;
    var markers = answerChoiceMarkers(fullText);
    var runs = sequentialAnswerChoiceRuns(markers);
    for (var runIndex = 0; runIndex < runs.length; runIndex += 1) {
      var run = runs[runIndex];
      for (var index = 0; index < run.length; index += 1) {
        var marker = run[index];
        var nextMarker = run[index + 1];
        var end = nextMarker ? nextMarker.start : fullText.length;
        if (startOffset >= marker.start && startOffset < end) {
          return true;
        }
      }
    }
    return false;
  }

  function answerChoiceMarkers(fullText) {
    var markers = [];
    var text = String(fullText || "");
    var markerPattern = /(^|[\n\r]|[.!?;:][\"'“”‘’]?\s+|\s{2,})([\"'“”‘’]?\s*)[(]?([a-jA-J])[\).](?=\s|$)/g;
    var match;
    while ((match = markerPattern.exec(text))) {
      markers.push({
        start: match.index + match[1].length + match[2].length,
        label: match[3].toLowerCase().charCodeAt(0)
      });
    }
    return markers;
  }

  function sequentialAnswerChoiceRuns(markers) {
    var runs = [];
    var current = [];
    markers.forEach(function (marker) {
      if (!current.length || marker.label === current[current.length - 1].label + 1) {
        current.push(marker);
        return;
      }
      if (current.length >= 2) runs.push(current);
      current = [marker];
    });
    if (current.length >= 2) runs.push(current);
    return runs;
  }

  function answerChoiceLabelCode(text) {
    var compact = String(text || "").trim().toLowerCase().replace(/^[\"'“”‘’]\s*/, "");
    var match = /^(?:[(]([a-j])[)]|([a-j])[\).])$/.exec(compact);
    if (!match) return null;
    return (match[1] || match[2]).charCodeAt(0);
  }

  function repairAnswerChoiceRuns(segments) {
    var markers = [];
    segments.forEach(function (segment, index) {
      if (!segment || segment.region === "right") return;
      var label = answerChoiceLabelCode(segment.text);
      if (label === null) return;
      markers.push({
        segmentIndex: index,
        label: label
      });
    });

    sequentialAnswerChoiceRuns(markers).forEach(function (run) {
      run.forEach(function (marker, runIndex) {
        var start = marker.segmentIndex;
        var nextMarker = run[runIndex + 1];
        var end = nextMarker ? nextMarker.segmentIndex : answerChoiceTailEnd(segments, start);
        for (var index = start; index < end; index += 1) {
          markAnswerChoiceSegment(segments[index]);
        }
      });
    });
    return segments;
  }

  function answerChoiceTailEnd(segments, start) {
    for (var index = start + 1; index < segments.length; index += 1) {
      var segment = segments[index];
      if (!segment) continue;
      if (segment.region === "right") return index;
      if (segment.role === "question_task") return index;
    }
    return segments.length;
  }

  function markAnswerChoiceSegment(segment) {
    if (!segment) return;
    if (segment.region === "right" || segment.role === "ui") return;
    segment.role = "choice";
  }

  function classifyRole(text, region, element, fullText, rects, startOffset, contextText) {
    var compact = text.trim().toLowerCase();
    if (isLikelyInterfaceText(text, element) || isLikelyInterfacePosition(text, rects)) {
      return "ui";
    }
    if (isAnswerChoiceText(text, fullText, startOffset, contextText)) {
      return "choice";
    }
    if (compact.endsWith("?") ||
      compact.indexOf("which of the following") !== -1 ||
      compact.indexOf("most likely") !== -1 ||
      compact.indexOf("best next step") !== -1) {
      return "question_task";
    }
    if (region === "right") return "explanation";
    return "stem";
  }

  function nodeIsVisibleText(node) {
    if (!node.textContent || !node.textContent.trim()) {
      return false;
    }
    var parent = node.parentElement;
    if (!parent) return false;
    var style = window.getComputedStyle(parent);
    if (style.display === "none" || style.visibility === "hidden") {
      return false;
    }
    return true;
  }

  window.__uworldTTSCaptureInternals = {
    classifyRole: classifyRole,
    isLikelyInterfaceText: isLikelyInterfaceText,
    isLikelyUnitText: isLikelyUnitText,
    isLikelyInterfacePosition: isLikelyInterfacePosition,
    rectIntersectsViewport: rectIntersectsViewport,
    isAnswerChoiceText: isAnswerChoiceText,
    repairAnswerChoiceRuns: repairAnswerChoiceRuns,
    splitTextIntoChunks: splitTextIntoChunks,
    textNodePathForNode: textNodePathForNode,
    captureTables: captureTables,
    captureMediaReferences: captureMediaReferences,
    answerStateForElement: answerStateForElement
  };

  window.captureUWorldSegments = function captureUWorldSegments(mode) {
    var walker = document.createTreeWalker(
      document.body,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode: function (node) {
          if (node.parentElement && node.parentElement.closest && node.parentElement.closest("table")) {
            return NodeFilter.FILTER_REJECT;
          }
          return nodeIsVisibleText(node) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        }
      }
    );

    var segments = [];
    var nodeIndex = 0;
    while (walker.nextNode()) {
      var node = walker.currentNode;
      var chunks = splitTextIntoChunks(node.textContent);
      chunks.forEach(function (chunk, chunkIndex) {
        var range = document.createRange();
        range.setStart(node, chunk.start);
        range.setEnd(node, chunk.end);
        var rects = rectsForRange(range);
        if (!rects.length) return;
        var region = classifyRegion(rects);
        var contextText = node.parentElement ? node.parentElement.textContent : node.textContent;
        var role = classifyRole(chunk.text, region, node.parentElement, node.textContent, rects, chunk.start, contextText);
        var answerState = role === "choice" ? answerStateForElement(node.parentElement, chunk.text, contextText) : {};
        var segment = {
          id: "seg-" + nodeIndex + "-" + chunkIndex,
          text: chunk.text,
          region: region,
          role: role,
          rects: rects,
          domPath: domPathForNode(node),
          textNodePath: textNodePathForNode(node),
          startOffset: chunk.start,
          endOffset: chunk.end
        };
        if (answerState.answerLabel) segment.answerLabel = answerState.answerLabel;
        if (answerState.isSelected) segment.isSelected = true;
        if (answerState.isCorrect) segment.isCorrect = true;
        segments.push(segment);
      });
      nodeIndex += 1;
    }
    repairAnswerChoiceRuns(segments);

    return {
      requestId: "uworld-" + Date.now().toString(36),
      mode: mode,
      pageUrl: window.location.href,
      title: document.title,
      viewport: { width: window.innerWidth, height: window.innerHeight },
      tables: captureTables(),
      media: captureMediaReferences(),
      segments: segments
    };
  };
})();
