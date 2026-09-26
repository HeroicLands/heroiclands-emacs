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
(require 'heroiclands-index)
(require 'heroiclands-server)
(require 'eglot)

(defgroup heroiclands-eglot nil
  "Language-server navigation for content notes."
  :group 'heroiclands)

(defcustom heroiclands-eglot-server-command nil
  "Command that starts the content language server.

Nil uses the exact server installed under `heroiclands-server-directory'.
A list of strings overrides that command for server development.
See Info node `(heroiclands)Content Language Server'."
  :type '(choice (const :tag "Pinned installed server" nil)
                 (repeat string))
  :group 'heroiclands-eglot)

(defun heroiclands-eglot--content-buffer-p ()
  "Whether this buffer visits a note in a configured content project."
  (and heroiclands-mode
       buffer-file-name
       (derived-mode-p 'markdown-mode 'gfm-mode)
       (heroiclands--note-p)
       (heroiclands-project-p (heroiclands--project-root))))

(defun heroiclands-eglot--contact (&rest _args)
  "Return the language-server command and selected foreign project roots."
  (unless (heroiclands-eglot--content-buffer-p)
    (user-error "Not in a HeroicLands content note"))
  (let ((root (heroiclands--project-root)))
    (append (or heroiclands-eglot-server-command
                (list (heroiclands-server-require-executable)))
            (list :initializationOptions
                  (lambda (_server)
                    (list :foreignRoots
                          (vconcat (heroiclands-index-project-roots root))))))))

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
