;;; heroiclands-hbs.el --- Handlebars helper completion -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Tom Rodriguez
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is part of heroiclands-emacs, and is free software: you may
;; redistribute it and/or modify it under the terms of the GNU General Public
;; License as published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.  It is distributed
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the LICENSE file for details.
;;
;; Completion for `{{helper}}' in SoHL's 483 .hbs templates.
;;
;; Helper names are READ from their definitions, never restated here, so a
;; helper added to src/ shows up after `M-x heroiclands-hbs-refresh'. Three
;; sources:
;;
;;   sohl      src/utils/handlebars-helpers.ts  (pure, H.registerHelper)
;;             src/sohl.ts                      (impure, Handlebars.registerHelper)
;;   foundry   client/applications/handlebars.mjs, the registerHelper({...}) block
;;   builtin   the Handlebars LANGUAGE keywords -- the one list stated
;;             literally, because it belongs to Handlebars itself, not to
;;             this project, and cannot drift with the codebase.
;;
;; Foundry lives on an external volume, so its scan result is cached to disk
;; and survives the volume being unmounted.

;;; Code:

(require 'subr-x)
(require 'cl-lib)

(defgroup heroiclands-hbs nil "Handlebars helper completion." :group 'heroiclands)

(defcustom heroiclands-hbs-foundry-source
  "/Volumes/Data/fvtt/foundryvtt-dev/client/applications/handlebars.mjs"
  "Foundry's Handlebars helper module.
NOTE: this checkout is one specific Foundry build and may differ from the
pinned `compatibility.minimum'. Helper NAMES are stable across builds;
deprecation flags may not be."
  :type 'file :group 'heroiclands-hbs)

(defcustom heroiclands-hbs-cache-file
  (expand-file-name "hbs-helpers.eld" user-emacs-directory)
  "Where the scanned helper table is cached."
  :type 'file :group 'heroiclands-hbs)

;; Handlebars language keywords. Block constructs take `{{#name}}...{{/name}}'.
(defconst heroiclands-hbs-builtins
  '(("if"     "Render the block when the argument is truthy." t)
    ("unless" "Render the block when the argument is falsy."  t)
    ("each"   "Iterate an array or object over the block."    t)
    ("with"   "Rebind the block's context to the argument."   t)
    ("lookup" "Look a property up dynamically by key."        nil)
    ("log"    "Write the arguments to the console."           nil))
  "Handlebars' own keywords: (NAME DOC BLOCK-P).")

(defvar heroiclands-hbs--cache nil
  "List of (NAME DOC SOURCE BLOCK-P DEPRECATED-P).")

;;;; ------------------------------------------------------------- scanning

(defun heroiclands-hbs--jsdoc-before (pos)
  "First sentence of the JSDoc block ending just before POS, or nil."
  (save-excursion
    (goto-char pos)
    (forward-line 0)
    ;; Step ABOVE the definition line, then skip blanks upward, then require
    ;; a */ terminator on the line we land on.
    (forward-line -1)
    (while (and (not (bobp)) (looking-at-p "[ \t]*$")) (forward-line -1))
    (when (looking-at-p "[ \t]*\\*/")
      (let ((end (point)))
        (when (re-search-backward "/\\*\\*" nil t)
          (let* ((raw (buffer-substring-no-properties (point) end))
                 (txt (replace-regexp-in-string "^[ \t]*\\*/?" "" raw))
                 (txt (replace-regexp-in-string "^[ \t]*/\\*\\*" "" txt))
                 ;; Stop at the first JSDoc tag.
                 (txt (car (split-string txt "@[a-z]+" t)))
                 (txt (string-trim (replace-regexp-in-string "[ \t\n]+" " " txt))))
            (unless (string-empty-p txt)
              ;; First sentence only.
              (if (string-match "\\`\\(.*?\\.\\)\\(?: \\|\\'\\)" txt)
                  (match-string 1 txt)
                txt))))))))

(defun heroiclands-hbs--deprecated-before-p (pos)
  "Non-nil when the JSDoc ending before POS carries @deprecated."
  (save-excursion
    (goto-char pos)
    (let ((start (max (point-min) (- pos 900))))
      (string-match-p "@deprecated"
                      (buffer-substring-no-properties start pos)))))

(defun heroiclands-hbs--scan-sohl (root)
  "Scan ROOT's TypeScript for registered helpers."
  (let (out)
    (dolist (rel '("src/utils/handlebars-helpers.ts" "src/sohl.ts"))
      (let ((f (expand-file-name rel root)))
        (when (file-readable-p f)
          (with-temp-buffer
            (insert-file-contents f)
            (goto-char (point-min))
            ;; Matches both `H.registerHelper("x"' and a name on the next line.
            (while (re-search-forward
                    "registerHelper(\\s-*\n?\\s-*[\"']\\([A-Za-z0-9_-]+\\)[\"']" nil t)
              (let* ((name (match-string 1))
                     (beg  (match-beginning 0))
                     (doc  (heroiclands-hbs--jsdoc-before beg)))
                (push (list name (or doc "SoHL helper.") "sohl" nil nil) out)))))))
    (nreverse out)))

(defun heroiclands-hbs--scan-foundry ()
  "Scan Foundry's handlebars module for its registered helpers."
  (let ((f heroiclands-hbs-foundry-source) out)
    (when (file-readable-p f)
      (with-temp-buffer
        (insert-file-contents f)
        ;; 1. The registerHelper({ ... }) block lists what is actually exposed.
        (goto-char (point-min))
        (when (re-search-forward "registerHelper(\\s-*{" nil t)
          (let* ((beg (point))
                 (end (save-excursion (goto-char (1- (point))) (forward-sexp) (point)))
                 (blk (buffer-substring-no-properties beg (min end (point-max))))
                 names)
            ;; Entries take three forms in that block:
            ;;   shorthand   `localize,'
            ;;   alias/arrow `formField: formGroup,'  `eq: (a,b) => a === b,'
            ;;   method      `and() {return ...},'
            ;; so accept a name followed by any of `,' `:' `(' or end of line,
            ;; and keep an inline body as the helper's documentation.
            (dolist (line (split-string blk "\n" t))
              (when (string-match
                     "\\`\\s-*\\([A-Za-z][A-Za-z0-9_]*\\)\\s-*\\(?:\\([,:(]\\)\\|\\'\\)" line)
                (let* ((name (match-string 1 line))
                       (rest (string-trim (substring line (match-end 1))))
                       (body (string-trim
                              (replace-regexp-in-string
                               "[,;]\\s-*\\'" ""
                               (replace-regexp-in-string
                                "\\s-*//.*\\'" ""
                                (replace-regexp-in-string
                                 "\\`)\\s-*" ""
                                 (replace-regexp-in-string "\\`[:(]\\s-*" "" rest)))))))
                  (push (cons name
                              (and (not (string-empty-p body))
                                   (string-match-p "=>\\|{\\|[A-Za-z]" body)
                                   body))
                        names))))
            ;; 2. For each, find its definition to recover doc + @deprecated.
            (dolist (pair (nreverse names))
              (let ((name (car pair)) (inline (cdr pair)) doc dep)
                (save-excursion
                  (goto-char (point-min))
                  (when (re-search-forward
                         (format "^\\(?:export \\)?function %s\\s-*(" (regexp-quote name)) nil t)
                    (let ((defpos (match-beginning 0)))
                      (setq doc (heroiclands-hbs--jsdoc-before defpos)
                            dep (heroiclands-hbs--deprecated-before-p defpos)))))
                ;; Prefer real JSDoc; fall back to the inline body, which for
                ;; the comparison operators IS the clearest documentation.
                (push (list name (or doc
                                     (and inline (concat "= " inline))
                                     "Foundry helper.")
                            "foundry" nil dep) out)))))))
    (nreverse out)))

;;;; ---------------------------------------------------------------- table

(defun heroiclands-hbs--project-root ()
  (or (when-let* ((p (project-current))) (project-root p)) default-directory))

;;;###autoload
(defun heroiclands-hbs-refresh (&optional quiet)
  "Rescan every source and rewrite the cache."
  (interactive)
  (let* ((sohl    (heroiclands-hbs--scan-sohl (heroiclands-hbs--project-root)))
         (foundry (heroiclands-hbs--scan-foundry))
         (builtin (mapcar (lambda (b)
                            (list (nth 0 b) (nth 1 b) "builtin" (nth 2 b) nil))
                          heroiclands-hbs-builtins))
         (prev    (and (null foundry) ; volume unmounted -> keep cached Foundry
                       (seq-filter (lambda (r) (equal (nth 2 r) "foundry"))
                                   (heroiclands-hbs--load-cache))))
         (all     (append builtin sohl (or foundry prev)))
         (tbl     (make-hash-table :test #'equal)))
    ;; SoHL wins over Foundry on a name clash: it is what actually registers last.
    (dolist (r all) (puthash (nth 0 r) r tbl))
    (setq heroiclands-hbs--cache
          (sort (hash-table-values tbl)
                (lambda (a b) (string< (nth 0 a) (nth 0 b)))))
    (with-temp-file heroiclands-hbs-cache-file
      (prin1 heroiclands-hbs--cache (current-buffer)))
    (unless quiet
      (message "Handlebars helpers: %d total (%d sohl, %d foundry, %d builtin)%s"
               (length heroiclands-hbs--cache)
               (seq-count (lambda (r) (equal (nth 2 r) "sohl")) heroiclands-hbs--cache)
               (seq-count (lambda (r) (equal (nth 2 r) "foundry")) heroiclands-hbs--cache)
               (seq-count (lambda (r) (equal (nth 2 r) "builtin")) heroiclands-hbs--cache)
               (if foundry "" "  [Foundry volume unmounted - used cache]")))
    heroiclands-hbs--cache))

(defun heroiclands-hbs--load-cache ()
  (when (file-readable-p heroiclands-hbs-cache-file)
    (with-temp-buffer
      (insert-file-contents heroiclands-hbs-cache-file)
      (ignore-errors (read (current-buffer))))))

(defun heroiclands-hbs-helpers ()
  "The helper table, loading or building it as needed."
  (or heroiclands-hbs--cache
      (setq heroiclands-hbs--cache (heroiclands-hbs--load-cache))
      (heroiclands-hbs-refresh t)))

;;;; ------------------------------------------------------------------ capf

(defun heroiclands-hbs--annotate (name)
  (when-let* ((r (assoc name (heroiclands-hbs-helpers))))
    (concat (if (nth 4 r) "  [DEPRECATED] " "  ")
            "(" (nth 2 r) ") " (or (nth 1 r) ""))))

(defun heroiclands-hbs--docsig (name)
  (when-let* ((r (assoc name (heroiclands-hbs-helpers)))) (nth 1 r)))

(defun heroiclands-hbs-capf ()
  "Complete a Handlebars helper after `{{', `{{#' or `{{/'."
  (when (looking-back "{{\\([#/]?\\)\\([A-Za-z0-9_-]*\\)" (max (point-min) (- (point) 64)))
    (let* ((sigil (match-string 1))
           (start (match-beginning 2))
           (all   (heroiclands-hbs-helpers))
           ;; `{{#' and `{{/' are block positions: offer block helpers first.
           (cands (if (member sigil '("#" "/"))
                      (append (mapcar #'car (seq-filter (lambda (r) (nth 3 r)) all))
                              (mapcar #'car (seq-remove (lambda (r) (nth 3 r)) all)))
                    (mapcar #'car all))))
      (list start (point)
            cands
            :annotation-function #'heroiclands-hbs--annotate
            :company-docsig #'heroiclands-hbs--docsig
            :exclusive 'no))))

;;;###autoload
(defun heroiclands-hbs-setup ()
  "Enable helper completion in this Handlebars buffer."
  (when (and buffer-file-name (string-suffix-p ".hbs" buffer-file-name))
    (add-hook 'completion-at-point-functions #'heroiclands-hbs-capf nil t)))

;;;###autoload
(defun heroiclands-hbs-describe (name)
  "Describe a Handlebars helper."
  (interactive
   (list (completing-read "Helper: " (mapcar #'car (heroiclands-hbs-helpers)) nil t)))
  (let ((r (assoc name (heroiclands-hbs-helpers))))
    (message "%s  (%s)%s  %s" (nth 0 r) (nth 2 r)
             (if (nth 4 r) "  [DEPRECATED]" "") (nth 1 r))))

(add-hook 'web-mode-hook #'heroiclands-hbs-setup)

(provide 'heroiclands-hbs)
;;; heroiclands-hbs.el ends here
