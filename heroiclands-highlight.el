;;; heroiclands-highlight.el --- Colour wikilink syntax -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'heroiclands)
(require 'font-lock)
(require 'rx)

(defgroup heroiclands-highlight nil
  "Syntax colouring for wikilinks in content notes."
  :group 'heroiclands)

(defface heroiclands-wikilink-address
  '((((class color) (background light)) :foreground "#6c3fd1" :weight semi-bold)
    (((class color) (background dark)) :foreground "#c4b0ff" :weight semi-bold)
    (t :weight bold))
  "The Address in a wikilink."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-anchor
  '((((class color) (background light)) :foreground "#8a63d2")
    (((class color) (background dark)) :foreground "#a894e0"))
  "The anchor in a wikilink."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-display
  '((t :inherit default :slant italic))
  "The readable text in a wikilink."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-delimiter
  '((t :inherit shadow))
  "The brackets and separators in a wikilink."
  :group 'heroiclands-highlight)

(defconst heroiclands-highlight--wikilink-re
  (rx (group "[[")
      (group (+ (not (any "]|#\n"))))
      (opt (group "#") (group (* (not (any "]|\n")))))
      (opt (group "|") (group (* (not (any "]\n")))))
      (group "]]"))
  "Match a wikilink with separate groups for its syntax parts.")

(defconst heroiclands-highlight--keywords
  `((,heroiclands-highlight--wikilink-re
     (1 'heroiclands-wikilink-delimiter prepend)
     (2 'heroiclands-wikilink-address prepend)
     (3 'heroiclands-wikilink-delimiter prepend t)
     (4 'heroiclands-wikilink-anchor prepend t)
     (5 'heroiclands-wikilink-delimiter prepend t)
     (6 'heroiclands-wikilink-display prepend t)
     (7 'heroiclands-wikilink-delimiter prepend)))
  "Font-lock keywords for wikilink syntax.")

(defun heroiclands-highlight-refresh ()
  "Recolour wikilinks in this buffer.

See Info node `(heroiclands)Seeing Them'."
  (interactive)
  (when font-lock-mode
    (font-lock-flush)
    (font-lock-ensure)))

(defun heroiclands-highlight-enable ()
  "Add wikilink syntax colouring to this buffer."
  (font-lock-add-keywords nil heroiclands-highlight--keywords t)
  (heroiclands-highlight-refresh))

(defun heroiclands-highlight-disable ()
  "Remove wikilink syntax colouring from this buffer."
  (font-lock-remove-keywords nil heroiclands-highlight--keywords)
  (heroiclands-highlight-refresh))

(provide 'heroiclands-highlight)
;;; heroiclands-highlight.el ends here
