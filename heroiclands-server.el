;;; heroiclands-server.el --- Pinned content server installation -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Tom Rodriguez
;;
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'heroiclands)
(require 'json)
(require 'subr-x)

(defgroup heroiclands-server nil
  "Installed content language server and its private indexes."
  :group 'heroiclands)

(defcustom heroiclands-server-directory
  (expand-file-name "heroiclands/content-language-server/" user-emacs-directory)
  "Directory containing the pinned content language server installation.

See Info node `(heroiclands)Content Language Server'."
  :type 'directory
  :group 'heroiclands-server)

(defcustom heroiclands-server-npm "npm"
  "npm executable used by `heroiclands-server-install'."
  :type 'string
  :group 'heroiclands-server)

(defvar heroiclands-server--paths (make-hash-table :test 'equal)
  "Private index paths returned by the installed server, keyed by project root.")

(defvar heroiclands-server--validity (make-hash-table :test 'equal)
  "Validated index states, keyed by index path.")

(defvar heroiclands-server--refresh-timer nil
  "Timer that updates open content buffers when private indexes change.")

(defvar-local heroiclands-server--buffer-state 'unseen
  "Private index file states visible to this content buffer.")

(defun heroiclands-server--read-json (file)
  "Read FILE as a JSON plist."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'plist)))

(defun heroiclands-server-executable ()
  "Return the installed content server executable, or nil.

See Info node `(heroiclands)Content Language Server'."
  (let ((file (expand-file-name
               "node_modules/.bin/heroiclands-content-language-server"
               heroiclands-server-directory)))
    (when (file-executable-p file) file)))

(defun heroiclands-server-require-executable ()
  "Return the installed server executable, or signal a setup error."
  (or (heroiclands-server-executable)
      (user-error "No content language server installed; run M-x heroiclands-server-install")))

(defun heroiclands-server--package-version ()
  "Return the generator version installed with the server, or nil."
  (let ((files '("node_modules/@heroiclands/content-language-server/node_modules/@heroiclands/package-build/package.json"
                 "node_modules/@heroiclands/package-build/package.json")))
    (when-let* ((file (seq-find #'file-readable-p
                                 (mapcar (lambda (name)
                                           (expand-file-name name heroiclands-server-directory))
                                         files))))
      (plist-get (heroiclands-server--read-json file) :version))))

(defun heroiclands-server-index-path (root)
  "Ask the installed server for ROOT's private index path.

The server owns cache path construction.  Return nil when the server is
not installed or the project configuration cannot be read."
  (when-let* ((binary (heroiclands-server-executable))
              (root (and (file-directory-p root) (file-truename root))))
    (or (gethash root heroiclands-server--paths)
        (with-temp-buffer
          (let ((default-directory (file-name-as-directory root)))
            (when (zerop (process-file binary nil t nil "--print-index-path"))
              (let ((file (string-trim (buffer-string))))
                (when (file-name-absolute-p file)
                  (puthash root file heroiclands-server--paths)
                  file))))))))

(defun heroiclands-server--file-state (file)
  "Return a cache key for FILE's current contents, or nil."
  (when-let* ((attrs (file-attributes file)))
    (list (file-attribute-size attrs)
          (file-attribute-modification-time attrs))))

(defun heroiclands-server--index-valid-p (file root)
  "Whether FILE is a complete index for ROOT and this server installation."
  (let* ((manifest (expand-file-name "metadata.json" (file-name-directory file)))
         (state (list (heroiclands-server--file-state file)
                      (heroiclands-server--file-state manifest)
                      (heroiclands-server--package-version)
                      (heroiclands-project-package root)))
         (cached (gethash file heroiclands-server--validity)))
    (if (equal state (car-safe cached))
        (cdr cached)
      (let ((valid
             (and (car state) (cadr state)
                  (condition-case nil
                      (let ((metadata (heroiclands-server--read-json manifest)))
                        (and (equal (plist-get metadata :package) (nth 3 state))
                             (equal (plist-get metadata :generatorVersion) (nth 2 state))
                             (with-temp-buffer
                               (insert-file-contents-literally file)
                               (equal (secure-hash 'sha256 (current-buffer))
                                      (plist-get metadata :sha256)))))
                    (error nil)))))
        (puthash file (cons state valid) heroiclands-server--validity)
        valid))))

(defun heroiclands-server-index-file (root)
  "Return ROOT's complete private index file, or nil.

Only the pinned server's package identity, generator version, and checksum
are accepted.  See Info node `(heroiclands)The Content Index'."
  (when-let* ((file (heroiclands-server-index-path root)))
    (when (heroiclands-server--index-valid-p file root) file)))

(defun heroiclands-server--refresh-buffers ()
  "Update content buffers whose validated private indexes have changed."
  (let ((active nil))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (bound-and-true-p heroiclands-mode)
          (setq active t)
          (when (and (fboundp 'heroiclands-index-files)
                     (fboundp 'heroiclands-mode-note-index))
            (let* ((files (ignore-errors
                            (heroiclands-index-files (heroiclands--project-root))))
                   (state (mapcar (lambda (file)
                                    (cons file (heroiclands-server--file-state file)))
                                  files)))
              (unless (equal state heroiclands-server--buffer-state)
                (setq heroiclands-server--buffer-state state)
                (heroiclands-mode-note-index)))))))
    (unless active
      (cancel-timer heroiclands-server--refresh-timer)
      (setq heroiclands-server--refresh-timer nil))))

(defun heroiclands-server--watch-mode ()
  "Watch private index publications while content buffers are open."
  (when (and heroiclands-mode (not heroiclands-server--refresh-timer))
    (setq heroiclands-server--refresh-timer
          (run-with-timer 2 2 #'heroiclands-server--refresh-buffers))))

(add-hook 'heroiclands-mode-hook #'heroiclands-server--watch-mode)

;;;###autoload
(defun heroiclands-server-install ()
  "Install the locked content language server under `heroiclands-server-directory'.

Installation runs asynchronously and uses the lockfile shipped with this
Emacs package.  See Info node `(heroiclands)Content Language Server'."
  (interactive)
  (let* ((source (expand-file-name "server" heroiclands-directory))
         (directory heroiclands-server-directory)
         (npm (or (executable-find heroiclands-server-npm)
                  (user-error "npm executable not found: %s" heroiclands-server-npm)))
         (buffer (get-buffer-create "*HeroicLands server install*")))
    (make-directory directory t)
    (dolist (name '("package.json" "package-lock.json"))
      (copy-file (expand-file-name name source)
                 (expand-file-name name directory) t))
    (with-current-buffer buffer (erase-buffer))
    (make-process
     :name "heroiclands-server-install"
     :buffer buffer
     :noquery t
     :command (list npm "ci" "--prefix" directory)
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (if (zerop (process-exit-status process))
             (progn
               (clrhash heroiclands-server--paths)
               (clrhash heroiclands-server--validity)
               (message "Content language server installed in %s" directory))
           (display-buffer buffer)
           (message "Content language server installation failed; see %s"
                    (buffer-name buffer))))))
    (message "Installing the content language server…")))

(provide 'heroiclands-server)
;;; heroiclands-server.el ends here
