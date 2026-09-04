;;; heroiclands-dataview.el --- Preview content-table queries -*- lexical-binding: t; -*-
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
;; A content note declares the tables it wants with a fenced `dataview' query,
;; and the build fills in the rows (`@heroiclands/package-build/engine/
;; content-tables.mjs').  Obsidian used to render those queries live while
;; authoring; nothing in Emacs does.
;;
;; This renders them *through the build's own expander* — the same parse,
;; select, and render functions the shipped table comes from — so the preview
;; cannot drift from what actually gets published.  The result is shown as an
;; overlay below each block: the buffer is never modified, so a preview can
;; never be saved into the note by accident.
;;
;;   C-c h d   toggle previews in this buffer
;;   C-c h D   refresh them
;;
;;; Code:

(require 'heroiclands)
(require 'json)
(require 'subr-x)

(defgroup heroiclands-dataview nil
  "Live preview of content-table queries."
  :group 'heroiclands)

(defcustom heroiclands-dataview-script
  (expand-file-name "heroiclands-dataview.mjs" heroiclands-directory)
  "Node script that renders a note's queries via the build's expander.

Ships beside this file, so it is found wherever the package is cloned."
  :type 'file :group 'heroiclands-dataview)

(defcustom heroiclands-dataview-node "node"
  "Node executable used to run `heroiclands-dataview-script'."
  :type 'string :group 'heroiclands-dataview)

(defcustom heroiclands-dataview-max-rows 40
  "Rows to show before the preview is truncated.  nil shows every row."
  :type '(choice integer (const nil)) :group 'heroiclands-dataview)

(defface heroiclands-dataview-table
  '((t :inherit shadow :extend t))
  "Face for a rendered table preview."
  :group 'heroiclands-dataview)

(defface heroiclands-dataview-error
  '((t :inherit error :extend t))
  "Face for a query the expander refused."
  :group 'heroiclands-dataview)

(defvar-local heroiclands-dataview--overlays nil
  "Overlays showing rendered tables in this buffer.")

(defvar-local heroiclands-dataview--process nil
  "In-flight render process for this buffer, if any.")

;;;; ------------------------------------------------------------ scanning

(defun heroiclands-dataview--blocks ()
  "End positions of each fenced `dataview' block, in document order.

Mirrors the fence scan the expander performs, so the Nth position here is
the Nth block the renderer reports."
  (save-excursion
    (goto-char (point-min))
    (let (ends)
      (while (not (eobp))
        (if (looking-at "^[ \t]*\\(`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\(.*\\)$")
            (let* ((marker (match-string 1))
                   (info (string-trim (match-string 2)))
                   (query (string-match-p "\\`dataview\\b" info))
                   (closer (format "^[ \t]*%c\\{%d,\\}[ \t]*$"
                                   (aref marker 0) (length marker))))
              (forward-line 1)
              (if (re-search-forward closer nil t)
                  (progn (when query (push (line-end-position) ends))
                         (forward-line 1))
                (goto-char (point-max))))
          (forward-line 1)))
      (nreverse ends))))

;;;; ------------------------------------------------------------ overlays

(defun heroiclands-dataview-clear ()
  "Remove every table preview from this buffer."
  (interactive)
  (mapc #'delete-overlay heroiclands-dataview--overlays)
  (setq heroiclands-dataview--overlays nil))

(defun heroiclands-dataview--truncate (table rows)
  "Trim TABLE to `heroiclands-dataview-max-rows', noting ROWS dropped."
  (if (null heroiclands-dataview-max-rows)
      table
    (let* ((lines (split-string table "\n"))
           ;; A markdown table's first two lines are its header and rule.
           (keep (+ 2 heroiclands-dataview-max-rows)))
      (if (<= (length lines) keep)
          table
        (concat (string-join (seq-take lines keep) "\n")
                (format "\n… %d more row%s"
                        (- rows heroiclands-dataview-max-rows)
                        (if (= 1 (- rows heroiclands-dataview-max-rows)) "" "s")))))))

(defun heroiclands-dataview--show (buffer payload)
  "Draw the tables PAYLOAD describes in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (heroiclands-dataview-clear)
      (let ((fatal (alist-get 'fatal payload))
            (blocks (alist-get 'blocks payload))
            (ends (heroiclands-dataview--blocks)))
        (cond
         (fatal (message "dataview: %s" fatal))
         ((null blocks) (message "dataview: no queries in this note"))
         (t
          (seq-do
           (lambda (block)
             (let* ((i (alist-get 'index block))
                    (pos (nth i ends))
                    (err (alist-get 'error block))
                    (rows (or (alist-get 'rows block) 0))
                    (table (alist-get 'table block)))
               (when pos
                 (let* ((body (if err
                                  (format "  ✗ %s" err)
                                (concat (heroiclands-dataview--truncate table rows)
                                        (format "\n  %d row%s"
                                                rows (if (= rows 1) "" "s")))))
                        (face (if err 'heroiclands-dataview-error
                                'heroiclands-dataview-table))
                        (ov (make-overlay pos pos)))
                   (overlay-put ov 'heroiclands-dataview t)
                   (overlay-put ov 'evaporate t)
                   (overlay-put ov 'after-string
                                (concat "\n" (propertize body 'face face) "\n"))
                   (push ov heroiclands-dataview--overlays)))))
           blocks)
          (message "dataview: rendered %d table%s from %s notes"
                   (length blocks) (if (= 1 (length blocks)) "" "s")
                   (or (alist-get 'notes payload) "?"))))))))

;;;; ------------------------------------------------------------- driving

;;;###autoload
(defun heroiclands-dataview-refresh ()
  "Render this note's `dataview' queries and show them as overlays.

The buffer's current text is sent to the renderer, so an unsaved edit to a
query previews what it now says.

See Info node `(heroiclands)Content Tables'."
  (interactive)
  (unless buffer-file-name
    (user-error "This buffer is not visiting a file"))
  (unless (file-exists-p heroiclands-dataview-script)
    (user-error "Renderer not found: %s" heroiclands-dataview-script))
  (when (process-live-p heroiclands-dataview--process)
    (delete-process heroiclands-dataview--process))
  (let* ((buffer (current-buffer))
         (text (buffer-substring-no-properties (point-min) (point-max)))
         (out (generate-new-buffer " *heroiclands-dataview*"))
         (proc (make-process
                :name "heroiclands-dataview"
                :buffer out
                :noquery t
                :connection-type 'pipe
                :command (list heroiclands-dataview-node
                               heroiclands-dataview-script
                               buffer-file-name "--stdin")
                :sentinel
                (lambda (_p event)
                  (when (string-match-p "\\`\\(finished\\|exited\\)" event)
                    (let ((raw (with-current-buffer out (buffer-string))))
                      (kill-buffer out)
                      (condition-case err
                          (heroiclands-dataview--show
                           buffer
                           (let ((json-object-type 'alist)
                                 (json-array-type 'list))
                             (json-read-from-string (string-trim raw))))
                        (error (message "dataview: unreadable output (%s): %s"
                                        (error-message-string err)
                                        (truncate-string-to-width
                                         (string-trim raw) 200))))))))))
    (setq heroiclands-dataview--process proc)
    (process-send-string proc text)
    (process-send-eof proc)
    (message "dataview: rendering…")))

;;;###autoload
(define-minor-mode heroiclands-dataview-mode
  "Show each `dataview' query's rendered table beneath it.

Each table is drawn as an overlay below its block, so the buffer is never
modified and a preview cannot be saved into the note.  Rendering goes through
the build's own expander, so a preview cannot disagree with what ships.

See Info node `(heroiclands)Content Tables'."
  :lighter " DV"
  (if heroiclands-dataview-mode
      (heroiclands-dataview-refresh)
    (heroiclands-dataview-clear)))

(define-key heroiclands-prefix-map (kbd "d") #'heroiclands-dataview-mode)
(define-key heroiclands-prefix-map (kbd "D") #'heroiclands-dataview-refresh)

(provide 'heroiclands-dataview)
;;; heroiclands-dataview.el ends here
