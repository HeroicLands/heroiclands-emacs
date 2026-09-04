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
;; Every content build walks the whole note tree and parses every note's
;; frontmatter, then throws the result away.  `content-build content-index'
;; publishes that walk instead: one JSON object per note, in JSON Lines, under
;; the project's `paths.contentIndex' (`build/content-index/<package>.jsonl').
;;
;; The artifact is derived and disposable — regenerating it costs a frontmatter
;; parse, not a build — so the intended way to use it is to rebuild it whenever
;; it looks stale rather than to keep it current automatically.
;;
;;   C-c h i   rebuild this project's content index
;;   C-c h I   run a jq query against it
;;
;;; Code:

(require 'heroiclands)
(require 'subr-x)

(defgroup heroiclands-index nil
  "The published content index."
  :group 'heroiclands)

(defcustom heroiclands-index-relative-dir "build/content-index"
  "Where a project writes its content index, relative to its root.

Mirrors `paths.contentIndex' in `package-build.config.yaml'; override it
here only for a project that relocates the directory."
  :type 'string :group 'heroiclands-index)

(defcustom heroiclands-index-jq "jq"
  "The jq executable used by `heroiclands-index-query'."
  :type 'string :group 'heroiclands-index)

(defcustom heroiclands-index-projects 'all
  "Which projects' content indexes to read, besides this one's.

A wikilink may name a note in **another package**, written in the canonical
form `<package>-<type>-<shortcode>' — `sohl-being-aurochs' cited from a
`thalorna' note.  Resolving one means holding that package's index too, so
this says which to load:

  `all'   every project `heroiclands-projects' finds that has one built.
  LIST    project directories, named or matched.  An entry containing a
          slash is a path; anything else is matched against the directory
          name of each project found, so \"sohl-thalorna\" selects it
          wherever it happens to be cloned.
  nil     this project only; a cross-package link cannot be resolved.

`all' is the default because the alternative is silent: an unresolvable
link is indistinguishable from a wrong one, so a package left out of the
list would have its links reported broken rather than unknown.

Only projects with an index already built contribute.  Nothing is built as
a side effect of reading — run \\[heroiclands-index-rebuild] in a project to
add it."
  :type '(choice (const :tag "Every project that has one" all)
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
  "The content index of the project at ROOT, or nil when none is built.

There is exactly one per project — a configuration declares a single
`contentPackage' — so the first `.jsonl' in the directory is it."
  (let* ((root (or root (heroiclands-index--root)))
         (dir (expand-file-name heroiclands-index-relative-dir root)))
    (car (and (file-directory-p dir)
              (directory-files dir t "\\.jsonl\\'" t)))))

(defun heroiclands-index-files (&optional root)
  "Every content index to resolve wikilinks against, from the project at ROOT.

This project's own index comes **last**, so that where two packages publish
the same bare `type-shortcode' slug, the local note is the one a local link
means.  Canonical `<package>-<type>-<shortcode>' keys are unambiguous and so
unaffected by the order.

Projects named in `heroiclands-index-projects' that have no index built
contribute nothing, silently: this is a read, and building someone else's
index is not this command's business."
  (let* ((root (or root (heroiclands-index--root)))
         (own (heroiclands-index-file root))
         (others
          (cond
           ((eq heroiclands-index-projects 'all)
            (seq-remove (lambda (d) (file-equal-p d root)) (heroiclands-projects)))
           ((listp heroiclands-index-projects)
            ;; A name selects the project of that name wherever it is; a
            ;; path names one directly. Neither assumes a layout.
            (seq-filter
             #'identity
             (mapcar
              (lambda (n)
                (if (string-search "/" n)
                    (and (file-directory-p (expand-file-name n)) (expand-file-name n))
                  (seq-find (lambda (p)
                              (equal n (file-name-nondirectory
                                        (directory-file-name p))))
                            (heroiclands-projects))))
              heroiclands-index-projects)))
           (t nil))))
    (append (delq nil (mapcar #'heroiclands-index-file others))
            (and own (list own)))))

;;;###autoload
(defun heroiclands-index-rebuild ()
  "Rebuild this project's content index, and report what it holds.

Runs `content-build content-index' from the project root, asynchronously.
Rebuilding is cheap and the file is derived, so this is the ordinary way to
bring the index up to date after editing notes.

Nothing rebuilds it for you: a note added since the last rebuild is invisible
to completion, to link following, and to normalization, all of which read the
index rather than the tree.

See Info node `(heroiclands)The Content Index'."
  (interactive)
  (let* ((root (heroiclands-index--root))
         (default-directory root)
         (out (generate-new-buffer " *heroiclands-index*")))
    (make-process
     :name "heroiclands-index"
     :buffer out
     :noquery t
     :command (list "npx" "content-build" "content-index")
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
                 ;; The CLI reports "<package> → <path> (N notes, K KiB)";
                 ;; show its own last line rather than paraphrasing it.
                 (message "%s" (car (last (split-string text "\n" t)))))
             (message "content-index failed (%d): %s" code
                      (truncate-string-to-width text 300)))))))
    (message "Rebuilding the content index…")))

;;;###autoload
(defun heroiclands-index-query (query)
  "Run jq QUERY against this project's content index, in a results buffer.

QUERY is a jq filter applied to each record, so it reads the note's own
frontmatter shape — `select (.type == \"being\")', `.sohl.body.weight.base'.
Rebuild first with \\[heroiclands-index-rebuild] if the index is stale.

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
