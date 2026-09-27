;;; heroiclands-eglot.el --- Content note language services through Eglot -*- lexical-binding: t; -*-
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
(require 'heroiclands-goto)
(require 'heroiclands-server)
(require 'eglot)
(require 'cl-lib)

(defgroup heroiclands-eglot nil
  "Language-server completion and navigation for content notes."
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

(defun heroiclands-eglot-capf ()
  "Complete content Addresses through Eglot in a note being authored.

Completion stays quiet while editing a settled wikilink.  Frontmatter
Address fields use the same server candidates.  See Info node
`(heroiclands)Completion'."
  (when (and (heroiclands-eglot--content-buffer-p)
             (eglot-managed-p)
             (or (heroiclands-goto--armed-p)
                 (not (heroiclands-goto-link-at-point))))
    (when-let* ((capf (eglot-completion-at-point)))
      (let* ((buffer (current-buffer))
             (table (nth 2 capf))
             (exit (plist-get (nthcdr 3 capf) :exit-function))
             (typed (when (heroiclands-goto--armed-p)
                      (buffer-substring-no-properties
                       heroiclands-goto--entry (point)))))
        (plist-put
         (nthcdr 3 capf) :exit-function
         (lambda (candidate status)
           (let ((item (or (get-text-property 0 'eglot--lsp-item candidate)
                           (when-let* ((proxy (cl-find candidate
                                                        (all-completions "" table)
                                                        :test #'string=)))
                             (get-text-property 0 'eglot--lsp-item proxy)))))
             (funcall exit candidate status)
             (when (and typed (memq status '(finished exact)) item)
               (with-current-buffer buffer
                 (heroiclands-goto--remember-selection item typed)
                 (heroiclands-goto--finish-paired-selection))))))
        (plist-put (nthcdr 3 capf) :exclusive 'no)
        capf))))

(defun heroiclands-eglot--manage-capf ()
  "Use the content CAPF while Eglot manages this note."
  (if (and (eglot-managed-p) (heroiclands-eglot--content-buffer-p))
      (progn
        (remove-hook 'completion-at-point-functions #'eglot-completion-at-point t)
        (add-hook 'completion-at-point-functions #'heroiclands-eglot-capf nil t))
    (remove-hook 'completion-at-point-functions #'heroiclands-eglot-capf t)))

(defun heroiclands-eglot--teardown-capf ()
  "Restore Eglot's ordinary completion when HeroicLands mode ends."
  (remove-hook 'completion-at-point-functions #'heroiclands-eglot-capf t)
  (when (eglot-managed-p)
    (add-hook 'completion-at-point-functions #'eglot-completion-at-point nil t)))

(add-hook 'heroiclands-mode-hook #'heroiclands-eglot--maybe-start)
(add-hook 'eglot-managed-mode-hook #'heroiclands-eglot--manage-capf)

(provide 'heroiclands-eglot)
;;; heroiclands-eglot.el ends here
