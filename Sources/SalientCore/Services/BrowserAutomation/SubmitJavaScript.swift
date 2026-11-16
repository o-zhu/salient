import Foundation

public enum SubmitJavaScript {
    public static func build() -> String {
        """
        (function () {
          function textOf(el) {
            return [
              el.innerText,
              el.value,
              el.getAttribute('aria-label'),
              el.getAttribute('title'),
              el.getAttribute('data-testid')
            ].filter(Boolean).join(' ').replace(/\\s+/g, ' ').trim();
          }

          function isVisible(el) {
            var style = getComputedStyle(el);
            var rect = el.getBoundingClientRect();
            return style.visibility !== 'hidden' &&
              style.display !== 'none' &&
              rect.width > 0 &&
              rect.height > 0 &&
              rect.bottom >= 0 &&
              rect.right >= 0 &&
              rect.top <= innerHeight &&
              rect.left <= innerWidth;
          }

          function clickSubmit(doc) {
            var candidates = Array.from(doc.querySelectorAll(
              'button, input[type=button], input[type=submit], [role=button], a'
            ));
            var submit = candidates.find(function (el) {
              if (el.disabled || el.getAttribute('aria-disabled') === 'true' || !isVisible(el)) return false;
              return /(^|\\b)submit(\\b|$)/i.test(textOf(el));
            });
            if (!submit) return false;
            submit.scrollIntoView({ block: 'center', inline: 'center' });
            submit.focus({ preventScroll: true });
            submit.click();
            return true;
          }

          if (clickSubmit(document)) return 'clicked';
          for (var i = 0; i < frames.length; i++) {
            try {
              if (clickSubmit(frames[i].document)) return 'clicked';
            } catch (e) {}
          }
          return 'Submit button not found';
        })()
        """
    }
}
