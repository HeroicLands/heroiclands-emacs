;;; heroiclands-index.el --- Rebuild and query the content index -*- lexical-binding: t; -*-
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
;; The pinned content language server owns an index outside the project build
;; tree.  It refreshes the current project at startup and after saves.
;;
;;   C-c h i   rebuild this project's content index
;;   C-c h I   run a jq query against it
;;
;;; Code:

(require 'heroiclands)
(require 'heroiclands-server)
(require 'subr-x)

(defgroup heroiclands-index nil
  "The published content index."
  :group 'heroiclands)

(defcustom heroiclands-index-jq "jq"
  "The jq executable used by `heroiclands-index-query'."
  :type 'string :group 'heroiclands-index)

(defcustom heroiclands-index-projects 'all
  "Which projects' content indexes to read, besides this one's.

A wikilink may name a note in **another package**, written in the canonical
form `<package>-<type>-<shortcode>' — `sohl-being-aurochs' cited from a
`thalorna' note.  Resolving one means holding that package's index too, so
this says which to load:

  `all'   every project `heroiclands-projects' finds.
  LIST    projects, named or located.  An entry containing a slash is a
          path.  Anything else is matched against the project\'s **package
          name** first and its directory name second, so \"thalorna\"
          selects the project publishing that package wherever it is
          cloned and whatever its directory is called.  The two are not
          the same: \"sohl-thalorna\" is a directory publishing the
          package \"thalorna\", and in this constellation no directory
          name matches its package name.
  nil     this project only; a cross-package link cannot be resolved.

`all' is the default because the alternative is silent: an unresolvable
link is indistinguishable from a wrong one, so a package left out of the
list would have its links reported broken rather than unknown.

Eglot passes selected roots to the language server, which builds missing
foreign indexes on first use.  Emacs link completion and highlighting read
only complete private indexes; reading does not build them.  The server
refreshes the current project at startup and after saves;
\\[heroiclands-index-rebuild] refreshes it on demand.  Restart Eglot after
changing this setting in an open content project."
  :type '(choice (const :tag "Every discovered project" all)
                 (repeat :tag "Named projects" string)
                 (const :tag "This project only" nil))
  :group 'heroiclands-index)

(defvar heroiclands-index-query-history nil
  "Minibuffer history of jq queries run against the content index.")

(defun heroiclands-index--root ()
  "The HeroicLands project root for the current buffer, or signal."
  (let ((root (heroiclands--project-root)))
    (unless (and root (heroiclands-project-p root))
      (user-error "Not inside a HeroicLands content project"))
    root))

(defun heroiclands-index-file (&optional root)
  "The validated private index of the project at ROOT, or nil when absent."
  (heroiclands-server-index-file (or root (heroiclands-index--root))))

(defun heroiclands-index-project-roots (&optional root)
  "Foreign project roots selected for the content project at ROOT.

Resolve `heroiclands-index-projects' without requiring an existing index.
The language server can build a selected project's private index when needed."
  (let* ((root (or root (heroiclands-index--root)))
         (projects (heroiclands-projects))
         (selected
          (cond
           ((eq heroiclands-index-projects 'all) projects)
           ((listp heroiclands-index-projects)
            (delq nil
                  (mapcar
                   (lambda (name)
                     (if (string-search "/" name)
                         (let ((path (expand-file-name name root)))
                           (and (file-directory-p path) path))
                       (or (seq-find
                            (lambda (project)
                              (equal (downcase name)
                                     (downcase (or (heroiclands-project-package
                                                    project) ""))))
                            projects)
                           (seq-find
                            (lambda (project)
                              (equal name (file-name-nondirectory
                                           (directory-file-name project))))
                            projects))))
                   heroiclands-index-projects)))
           (t nil)))
         (own (file-truename root)))
    (delete-dups
     (seq-remove (lambda (project) (equal project own))
                 (mapcar #'file-truename selected)))))

(defun heroiclands-index-sources (&optional root)
  "Index files and their project roots for the content project at ROOT.

This project's own index comes **last**, so that where two packages publish
the same bare `type-shortcode' slug, the local note is the one a local link
means.  Canonical `<package>-<type>-<shortcode>' keys are unambiguous and so
unaffected by the order.

Projects named in `heroiclands-index-projects' without a complete private
index contribute nothing; this read never rebuilds a foreign project."
  (let* ((root (or root (heroiclands-index--root)))
         (own (heroiclands-index-file root)))
    (append (delq nil (mapcar (lambda (project)
                               (when-let* ((file (heroiclands-index-file project)))
                                 (cons file project)))
                             (heroiclands-index-project-roots root)))
            (and own (list (cons own root))))))

(defun heroiclands-index-files (&optional root)
  "Every content index selected for the content project at ROOT.

The local index comes last.  Foreign projects without a complete private
index contribute nothing; this read never rebuilds them."
  (mapcar #'car (heroiclands-index-sources root)))

;;;###autoload
(defun heroiclands-index-rebuild ()
  "Refresh this project's private content index through the pinned server.

The server also refreshes its index when it starts and after saves.  This
command is a manual recovery action for the current project only.

See Info node `(heroiclands)The Content Index'."
  (interactive)
  (let* ((root (heroiclands-index--root))
         (binary (heroiclands-server-require-executable))
         (default-directory root)
         (out (generate-new-buffer " *heroiclands-index*")))
    (make-process
     :name "heroiclands-index"
     :buffer out
     :noquery t
     :command (list binary "--rebuild-index")
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((text (string-trim (with-current-buffer out (buffer-string))))
               (code (process-exit-status proc)))
           (kill-buffer out)
           (if (zerop code)
               (progn
                 ;; Every content buffer is now looking at a stale answer:
                 ;; its lighter, and any broken-link highlighting, were
                 ;; computed against the index that has just been replaced.
                 (dolist (buf (buffer-list))
                   (with-current-buffer buf
                     (when (bound-and-true-p heroiclands-mode)
                       (heroiclands-mode-note-index)
                       (when (fboundp 'heroiclands-highlight-refresh)
                         (heroiclands-highlight-refresh)))))
                 (message "%s" (car (last (split-string text "\n" t)))))
             (message "Content index refresh failed (%d): %s" code
                      (truncate-string-to-width text 300)))))))
    (message "Refreshing the content index…")))

;;;###autoload
(defun heroiclands-index-query (query)
  "Run jq QUERY against this project's content index, in a results buffer.

QUERY is a jq filter applied to each record, so it reads the note's own
frontmatter shape — `select (.type == \"being\")', `.sohl.body.weight.base'.
Refresh first with \\[heroiclands-index-rebuild] if the index is stale.

See Info node `(heroiclands)Querying Content' for worked recipes, and Info
node `(heroiclands)Record Format' for every field a record carries."
  (interactive
   (list (read-string "jq: " nil 'heroiclands-index-query-history)))
  (let* ((root (heroiclands-index--root))
         (file (heroiclands-index-file root)))
    (unless file
      (user-error "No content index built — run %s first"
                  (substitute-command-keys "\\[heroiclands-index-rebuild]")))
    (let ((buf (get-buffer-create "*content index*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (call-process heroiclands-index-jq nil t nil "-c" query file)
          (goto-char (point-min)))
        (setq-local default-directory root)
        (view-mode 1))
      (pop-to-buffer buf))))

(define-key heroiclands-prefix-map (kbd "i") #'heroiclands-index-rebuild)
(define-key heroiclands-prefix-map (kbd "I") #'heroiclands-index-query)

(provide 'heroiclands-index)
;;; heroiclands-index.el ends here
