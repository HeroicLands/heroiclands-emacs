;;; heroiclands-highlight-test.el --- Wikilink presentation checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'heroiclands-highlight)

(ert-deftest heroiclands-highlight-colours-syntax-without-an-index ()
  (with-temp-buffer
    (insert "[[unknown-note#missing|Visible name]]")
    (font-lock-mode 1)
    (heroiclands-highlight-enable)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "unknown-note")
    (should (memq 'heroiclands-wikilink-address
                  (get-text-property (match-beginning 0) 'face)))
    (search-forward "missing")
    (should (memq 'heroiclands-wikilink-anchor
                  (get-text-property (match-beginning 0) 'face)))
    (search-forward "Visible name")
    (should (memq 'heroiclands-wikilink-display
                  (get-text-property (match-beginning 0) 'face)))
    (heroiclands-highlight-disable)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "unknown-note")
    (should-not (memq 'heroiclands-wikilink-address
                      (get-text-property (match-beginning 0) 'face)))))

;;; heroiclands-highlight-test.el ends here
