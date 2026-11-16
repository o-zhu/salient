import Foundation

public struct UWorldQuestionProgress: Codable, Equatable, Sendable {
    public var currentQuestion: Int?
    public var totalQuestions: Int?
    public var candidateCount: Int
    public var activeCandidateCount: Int
    public var minQuestionNumber: Int?
    public var maxQuestionNumber: Int?
    public var blockingDialogDetected: Bool
    public var confidence: String

    public init(
        currentQuestion: Int?,
        totalQuestions: Int?,
        candidateCount: Int,
        activeCandidateCount: Int,
        minQuestionNumber: Int?,
        maxQuestionNumber: Int?,
        blockingDialogDetected: Bool = false,
        confidence: String
    ) {
        self.currentQuestion = currentQuestion
        self.totalQuestions = totalQuestions
        self.candidateCount = candidateCount
        self.activeCandidateCount = activeCandidateCount
        self.minQuestionNumber = minQuestionNumber
        self.maxQuestionNumber = maxQuestionNumber
        self.blockingDialogDetected = blockingDialogDetected
        self.confidence = confidence
    }

    public func navigationRefusalReason(stopBeforeQuestion: Int) -> String? {
        if blockingDialogDetected {
            return "blocking_dialog_detected"
        }
        guard let currentQuestion else {
            return "question_progress_unavailable"
        }
        if currentQuestion >= stopBeforeQuestion {
            return "question_\(currentQuestion)_at_or_after_stop_before_\(stopBeforeQuestion)"
        }
        if let totalQuestions, currentQuestion >= totalQuestions {
            return "question_\(currentQuestion)_is_final_of_\(totalQuestions)"
        }
        return nil
    }
}

public enum UWorldQuestionProgressJavaScript {
    public static func build() -> String {
        """
        (function () {
          function clean(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
          }

          function isRendered(element) {
            var style = window.getComputedStyle(element);
            var rect = element.getBoundingClientRect();
            return style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0;
          }

          function activeState(element) {
            var chain = [element, element.parentElement, element.parentElement && element.parentElement.parentElement]
              .filter(Boolean);
            var tokens = [];
            chain.forEach(function (node) {
              [
                node.className,
                node.getAttribute('aria-current'),
                node.getAttribute('aria-selected'),
                node.getAttribute('data-state'),
                node.getAttribute('data-selected'),
                node.getAttribute('data-active')
              ].forEach(function (value) {
                String(value || '')
                  .toLowerCase()
                  .split(/[^a-z0-9]+/)
                  .filter(Boolean)
                  .forEach(function (token) { tokens.push(token); });
              });
            });
            return tokens.indexOf('active') >= 0 ||
              tokens.indexOf('selected') >= 0 ||
              tokens.indexOf('current') >= 0 ||
              tokens.indexOf('focus') >= 0 ||
              tokens.indexOf('chosen') >= 0 ||
              /^(true|page|step)$/i.test(String(element.getAttribute('aria-current') || '')) ||
              /^true$/i.test(String(element.getAttribute('aria-selected') || ''));
          }

          function bestQuestionRail(candidates) {
            var groups = {};
            candidates.forEach(function (candidate) {
              var key = Math.round(candidate.x / 20) + ':' + Math.round(candidate.w / 8) + ':' + Math.round(candidate.h / 8);
              if (!groups[key]) groups[key] = [];
              groups[key].push(candidate);
            });
            var rails = Object.keys(groups).map(function (key) {
              var values = groups[key].slice().sort(function (a, b) {
                if (a.n !== b.n) return a.n - b.n;
                return a.y - b.y;
              });
              var seen = {};
              var unique = values.filter(function (candidate) {
                if (seen[candidate.n]) return false;
                seen[candidate.n] = true;
                return true;
              });
              var expected = 1;
              var contiguous = [];
              unique.forEach(function (candidate) {
                if (candidate.n === expected) {
                  contiguous.push(candidate);
                  expected += 1;
                }
              });
              return { key: key, values: contiguous, count: contiguous.length };
            }).filter(function (rail) {
              return rail.count >= 10;
            }).sort(function (a, b) {
              if (b.count !== a.count) return b.count - a.count;
              return a.values[0].x - b.values[0].x;
            });
            return rails[0] || null;
          }

          function attributeTokens(element) {
            return clean([
              element.className,
              element.id,
              element.getAttribute('aria-label'),
              element.getAttribute('title'),
              element.getAttribute('data-testid'),
              element.getAttribute('role')
            ].filter(Boolean).join(' ')).toLowerCase();
          }

          function progressTextCandidate(element) {
            if (!isRendered(element)) return null;
            var text = clean(
              element.innerText ||
              element.textContent ||
              element.value ||
              element.getAttribute('aria-label') ||
              element.getAttribute('title') ||
              ''
            );
            if (text.length > 100) return null;

            var explicitPattern = new RegExp('\\\\b(?:question|q)\\\\s*(\\\\d{1,3})\\\\s*(?:of|/)\\\\s*(\\\\d{1,3})\\\\b', 'i');
            var compactPattern = new RegExp('^\\\\s*(\\\\d{1,3})\\\\s*(?:of|/)\\\\s*(\\\\d{1,3})\\\\s*$', 'i');
            var match = text.match(explicitPattern) || text.match(compactPattern);
            if (!match) return null;

            var current = parseInt(match[1], 10);
            var total = parseInt(match[2], 10);
            if (!(current >= 1 && total >= current && total <= 120)) return null;

            var attrText = attributeTokens(element);
            var looksLikeProgress =
              /question|progress|pagination|pager|nav|counter|current|toolbar|test/.test(attrText) ||
              /\\b(?:question|q)\\b/i.test(text);
            if (!looksLikeProgress) return null;

            return {
              currentQuestion: current,
              totalQuestions: total
            };
          }

          function bestProgressText() {
            var progressCandidates = [];
            Array.from(document.querySelectorAll('button,[role=button],a,li,span,div,p,label,strong,b,small')).forEach(function (element) {
              var candidate = progressTextCandidate(element);
              if (candidate) progressCandidates.push(candidate);
            });
            return progressCandidates[0] || null;
          }

          var candidates = [];
          Array.from(document.querySelectorAll('button,[role=button],a,li,span,div')).forEach(function (element) {
            if (!isRendered(element)) return;
            var text = clean(element.innerText || element.textContent || element.value || '');
            if (!/^\\d{1,3}$/.test(text)) return;
            var number = parseInt(text, 10);
            if (number < 1 || number > 120) return;
            var rect = element.getBoundingClientRect();
            if (rect.width < 12 || rect.width > 80 || rect.height < 12 || rect.height > 80) return;
            candidates.push({
              n: number,
              x: Math.round(rect.left),
              y: Math.round(rect.top),
              w: Math.round(rect.width),
              h: Math.round(rect.height),
              active: activeState(element)
            });
          });

          var rail = bestQuestionRail(candidates);
          var railValues = rail ? rail.values : [];
          var active = railValues.filter(function (candidate) { return candidate.active; });
          var currentQuestion = active.length === 1 ? active[0].n : null;
          var numbers = railValues.map(function (candidate) { return candidate.n; });
          var minQuestionNumber = numbers.length ? Math.min.apply(null, numbers) : null;
          var maxQuestionNumber = numbers.length ? Math.max.apply(null, numbers) : null;
          var progressText = currentQuestion === null ? bestProgressText() : null;
          if (progressText) {
            currentQuestion = progressText.currentQuestion;
            if (maxQuestionNumber === null) maxQuestionNumber = progressText.totalQuestions;
            if (minQuestionNumber === null) minQuestionNumber = 1;
          }
          var totalQuestions = maxQuestionNumber;
          var blockingDialogDetected = Array.from(document.querySelectorAll('[role=dialog],[aria-modal=true],.modal,.modal-dialog,.swal2-popup,.ui-dialog'))
            .some(function (element) { return isRendered(element); });

          return JSON.stringify({
            currentQuestion: currentQuestion,
            totalQuestions: totalQuestions,
            candidateCount: railValues.length || (progressText ? 1 : 0),
            activeCandidateCount: active.length,
            minQuestionNumber: minQuestionNumber,
            maxQuestionNumber: maxQuestionNumber,
            blockingDialogDetected: blockingDialogDetected,
            confidence: currentQuestion !== null && railValues.length >= 10
              ? 'active_numeric_rail'
              : (progressText ? 'progress_text' : 'unreliable')
          });
        })()
        """
    }
}
