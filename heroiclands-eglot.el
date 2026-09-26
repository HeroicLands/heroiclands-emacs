;;; heroiclands-eglot.el --- Content note navigation through Eglot -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Tom Rodriguez
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you may redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.
;;
;;; Code:

(require 'heroiclands)
(require 'eglot)

(defgroup heroiclands-eglot nil
  "Language-server navigation for content notes."
  :group 'heroiclands)

(defcustom heroiclands-eglot-server-command nil
  "Command that starts the content language server.

Nil uses this project's installed
`node_modules/.bin/heroiclands-content-language-server'.  A list of strings
overrides that command, for instance when developing a server checkout."
  :type '(choice (const :tag "Project-installed server" nil)
                 (repeat string))
  :group 'heroiclands-eglot)

(defun heroiclands-eglot--content-buffer-p ()
  "Whether this buffer visits a note in its HeroicLands content tree."
  (and heroiclands-mode
       buffer-file-name
       (derived-mode-p 'markdown-mode 'gfm-mode)
       (when-let* ((root (heroiclands--project-root))
                   ((heroiclands-project-p root))
                   (content (expand-file-name
                             (or (and (fboundp 'heroiclands-goto--content-dir)
                                      (heroiclands-goto--content-dir root))
                                 "assets/content")
                             root)))
         (file-in-directory-p buffer-file-name content))))

(defun heroiclands-eglot--contact (&rest _args)
  "Return the language-server command for this content project."
  (unless (heroiclands-eglot--content-buffer-p)
    (user-error "Not in a HeroicLands content note"))
  (let* ((root (heroiclands--project-root))
         (binary (expand-file-name
                  "node_modules/.bin/heroiclands-content-language-server"
                  root)))
    (or heroiclands-eglot-server-command
        (if (file-executable-p binary)
            (list binary)
          (user-error "No content language server at %s; run npm ci in this project"
                      binary)))))

(defun heroiclands-eglot--maybe-start ()
  "Start Eglot in a HeroicLands content note."
  (when (heroiclands-eglot--content-buffer-p)
    ;; The server mapping belongs to this buffer.  A Markdown file elsewhere
    ;; keeps whichever server the user's normal Eglot setup selects.
    (unless (eq (cdar eglot-server-programs) 'heroiclands-eglot--contact)
      (setq-local eglot-server-programs
                  (cons '((markdown-mode gfm-mode) . heroiclands-eglot--contact)
                        eglot-server-programs)))
    (eglot-ensure)))

(add-hook 'heroiclands-mode-hook #'heroiclands-eglot--maybe-start)

(provide 'heroiclands-eglot)
;;; heroiclands-eglot.el ends here
