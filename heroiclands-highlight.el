;;; heroiclands-highlight.el --- Make wikilinks visible as wikilinks -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Tom Rodriguez
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you may redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  It is distributed WITHOUT ANY WARRANTY; without even the
;; implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the LICENSE file for details.
;;
;; A wikilink is `[[address#anchor|display text]]', and in plain markdown all
;; four parts look like prose.  This colours them, and colours them by *part*,
;; because they are not equally interesting: the address has to be exactly
;; right and nobody can read it, the display text is what a reader actually
;; sees, and the brackets are structure.
;;
;; It also says whether the link WORKS.  The content index knows every address
;; in the package and every anchor each note declares, so a link naming
;; something that is not there can be shown as broken while it is being
;; written, rather than at build time.  That is the point of highlighting here
;; rather than adding a generic wikilink regexp: the colour carries a fact, not
;; just a category.
;;
;; A broken link is only ever reported against a *built* index.  With no index
;; the package cannot tell a dead link from an unbuilt one, so it says nothing
;; and everything is drawn as an ordinary link — silence rather than a buffer
;; full of false alarms after a fresh clone.
;;
;;; Code:

(require 'heroiclands)
(require 'heroiclands-index)
(require 'heroiclands-goto)
(require 'font-lock)
(require 'rx)

(defgroup heroiclands-highlight nil
  "Highlighting for wikilinks in content notes."
  :group 'heroiclands)

(defcustom heroiclands-highlight-check-targets t
  "Whether to draw a link whose target is unknown as broken.

Checked against the content index, so it is only as current as the last
\\[heroiclands-index-rebuild].  With no index built, nothing is reported
broken: the package cannot distinguish a dead link from an unbuilt index,
and guessing would fill a fresh checkout with false alarms."
  :type 'boolean :group 'heroiclands-highlight)

;;;; ---------------------------------------------------------------- faces

(defface heroiclands-wikilink-address
  '((((class color) (background light)) :foreground "#6c3fd1" :weight semi-bold)
    (((class color) (background dark)) :foreground "#c4b0ff" :weight semi-bold)
    (t :weight bold))
  "The address half of a wikilink — the part that has to be exactly right."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-anchor
  '((((class color) (background light)) :foreground "#8a63d2")
    (((class color) (background dark)) :foreground "#a894e0"))
  "The `#anchor' of a wikilink: a section within the note it names."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-display
  '((t :inherit default :slant italic))
  "The display half of a wikilink — the words a reader actually sees.

Kept close to body text on purpose: it *is* the prose, and colouring it
like a link would make the sentence harder to read rather than easier."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-delimiter
  '((t :inherit shadow))
  "The brackets and separators of a wikilink: structure, so it recedes."
  :group 'heroiclands-highlight)

(defface heroiclands-wikilink-broken
  '((((class color) (background light))
     :foreground "#b3261e" :underline (:style wave :color "#b3261e"))
    (((class color) (background dark))
     :foreground "#ff8a80" :underline (:style wave :color "#ff8a80"))
    (t :inherit font-lock-warning-face :underline t))
  "A wikilink naming a note, or an anchor, the content index does not hold."
  :group 'heroiclands-highlight)

;;;; -------------------------------------------------------------- matching

(defconst heroiclands-highlight--wikilink-re
  (rx (group "[[")
      (group (+ (not (any "]|#\n"))))
      (opt (group "#") (group (* (not (any "]|\n")))))
      (opt (group "|") (group (* (not (any "]\n")))))
      (group "]]"))
  "Matches a wikilink, one group per part.

1 `[[' - 2 address - 3 `#' - 4 anchor - 5 `|' - 6 display - 7 `]]'.")

(defvar-local heroiclands-highlight--index nil
  "Cons of (INDEX-FILE-STATE . PLIST) for this buffer's project.

Font lock runs constantly, so the index is resolved once and reused rather
than located and re-read per link.")

(defvar-local heroiclands-highlight--files 'unset
  "This buffer's index files, resolved once.

Resolving them walks the constellation and stats directories, which at
0.3 ms a call is nothing until font lock asks per link on every keystroke.
The symbol `unset' distinguishes not-yet-looked from looked-and-found-none,
which nil alone cannot.")

(defun heroiclands-highlight--files ()
  "The index files for this buffer, resolved at most once per buffer."
  (when (eq heroiclands-highlight--files 'unset)
    (setq heroiclands-highlight--files
          (or (ignore-errors
                (heroiclands-index-files (heroiclands-index--root)))
              nil)))
  heroiclands-highlight--files)

(defun heroiclands-highlight--index ()
  "This buffer's parsed content index, or nil when none is built.

Reads every index `heroiclands-index-projects' selects, so a link written
in the canonical `<package>-<type>-<shortcode>' form resolves against the
package that actually publishes it rather than being reported broken."
  (when heroiclands-highlight-check-targets
    (when-let* ((files (heroiclands-highlight--files))
                (state (heroiclands-goto--index-key files)))
      (unless (equal state (car heroiclands-highlight--index))
        (setq heroiclands-highlight--index
              (cons state (ignore-errors (heroiclands-goto--index files)))))
      (cdr heroiclands-highlight--index))))

(defun heroiclands-highlight--answerable-p (target index)
  "Whether the index could say anything about TARGET at all.

An address is answerable when its first segment names either a content
type this build knows — so it is a local `type-shortcode' slug — or a
package whose index is actually loaded.

Anything else names a package that is not held: `thalorna-being-x' with no
thalorna index says nothing about whether that note exists.  Reporting it
broken would be a guess dressed as a fact, and the first thing anyone would
do is stop trusting the colour."
  (when-let* ((seg (car (split-string target "[-/]"))))
    (or (gethash seg (plist-get index :types))
        (gethash seg (plist-get index :packages)))))

(defun heroiclands-highlight--broken-p (address anchor)
  "Whether ADDRESS, or ANCHOR within it, is one the index says is absent.

Nil whenever the answer is not knowable — no index, no target text, or a
target belonging to a package that is not loaded — so uncertainty never
renders as an error."
  ;; `save-match-data' is load-bearing, not defensive. Font lock evaluates
  ;; each group's face form with the match still current, and the lookups
  ;; below run `string-match' internally — without this the data is clobbered
  ;; partway through and font lock fails on the groups it has not read yet
  ;; ("No match 7 in highlight").
  (save-match-data
    (when-let* ((index (heroiclands-highlight--index))
                (target (and (stringp address) (string-trim address)))
                ((not (string-empty-p target))))
      (let* ((normal (heroiclands-goto--normalize target))
             (record (gethash normal (plist-get index :table))))
        (cond
         ;; Not held is not the same as not there.
         ((and (null record)
               (not (heroiclands-highlight--answerable-p normal index)))
          nil)
         ((null record) t)
         ;; A named anchor the note does not declare is as dead as a bad
         ;; address: the link resolves to a page that will not exist.
         ((and (stringp anchor) (not (string-empty-p anchor))
               (not (seq-find (lambda (a)
                                (equal (downcase (plist-get a :slug))
                                       (downcase anchor)))
                              (append (plist-get record :anchors) nil))))
          t)
         (t nil))))))

(defun heroiclands-highlight--address-face ()
  "The face for the address of the wikilink just matched."
  (if (heroiclands-highlight--broken-p (match-string 2) (match-string 4))
      'heroiclands-wikilink-broken
    'heroiclands-wikilink-address))

(defun heroiclands-highlight--anchor-face ()
  "The face for the anchor of the wikilink just matched."
  (if (heroiclands-highlight--broken-p (match-string 2) (match-string 4))
      'heroiclands-wikilink-broken
    'heroiclands-wikilink-anchor))

(defconst heroiclands-highlight--keywords
  `((,heroiclands-highlight--wikilink-re
     (1 'heroiclands-wikilink-delimiter prepend)
     (2 (heroiclands-highlight--address-face) prepend)
     (3 'heroiclands-wikilink-delimiter prepend t)
     (4 (heroiclands-highlight--anchor-face) prepend t)
     (5 'heroiclands-wikilink-delimiter prepend t)
     (6 'heroiclands-wikilink-display prepend t)
     (7 'heroiclands-wikilink-delimiter prepend)))
  "Font-lock keywords for wikilinks.

`prepend' rather than `t': markdown-mode has already fontified the line, and
these sit on top of that without erasing it.  The optional groups are marked
LAXMATCH, since a link need carry neither anchor nor display text.")

;;;; ----------------------------------------------------------------- setup

(defun heroiclands-highlight-refresh ()
  "Re-examine every wikilink in this buffer.

Worth running after \\[heroiclands-index-rebuild]: the highlighting is a view
of the index, and a link that was broken before a rebuild may not be after."
  (interactive)
  (setq heroiclands-highlight--index nil
        heroiclands-highlight--files 'unset)
  (when font-lock-mode
    (font-lock-flush)
    (font-lock-ensure)))

(defun heroiclands-highlight-enable ()
  "Add wikilink highlighting to this buffer."
  (font-lock-add-keywords nil heroiclands-highlight--keywords t)
  (heroiclands-highlight-refresh))

(defun heroiclands-highlight-disable ()
  "Remove wikilink highlighting from this buffer."
  (font-lock-remove-keywords nil heroiclands-highlight--keywords)
  (setq heroiclands-highlight--index nil
        heroiclands-highlight--files 'unset)
  (when font-lock-mode
    (font-lock-flush)
    (font-lock-ensure)))

(provide 'heroiclands-highlight)
;;; heroiclands-highlight.el ends here
