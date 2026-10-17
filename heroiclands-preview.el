;;; heroiclands-preview.el --- Live content page preview -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'heroiclands)
(require 'heroiclands-server)
(require 'browse-url)
(require 'cl-lib)
(require 'json)

(defgroup heroiclands-preview nil
  "Browser preview of the active content note."
  :group 'heroiclands)

(defcustom heroiclands-preview-idle-delay 3
  "Seconds of inactivity before rendering a changed note.

See Info node `(heroiclands)Live Preview'."
  :type 'number :group 'heroiclands-preview)

(defcustom heroiclands-preview-new-window t
  "Ask `browse-url' to open the preview in a separate browser window.

The browser controls whether this request creates a window or tab.
See Info node `(heroiclands)Live Preview'."
  :type 'boolean :group 'heroiclands-preview)

(defcustom heroiclands-preview-show-infobox t
  "Show locally available infobox fields beside a note when it has them.

Set this buffer-locally to hide a note's infobox, then run
`heroiclands-preview-refresh'.  See Info node `(heroiclands)Live Preview'."
  :type 'boolean :group 'heroiclands-preview)

(defcustom heroiclands-preview-node "node"
  "Node executable used by the live page renderer.

See Info node `(heroiclands)Live Preview'."
  :type 'string :group 'heroiclands-preview)

(defvar-local heroiclands-preview--process nil)
(defvar-local heroiclands-preview-mode nil)
(defvar-local heroiclands-preview--output nil)
(defvar-local heroiclands-preview--timer nil)
(defvar-local heroiclands-preview--generation 0)
(defvar-local heroiclands-preview--pending "")
(defvar-local heroiclands-preview--ready nil)
(defvar-local heroiclands-preview--url nil)
(defvar-local heroiclands-preview--opened nil)
(defvar-local heroiclands-preview--frame nil)

(defun heroiclands-preview--send (message)
  "Send MESSAGE as one JSON line to this buffer's renderer."
  (when (process-live-p heroiclands-preview--process)
    (process-send-string heroiclands-preview--process
                         (concat (json-serialize message) "\n"))))

(defun heroiclands-preview--render ()
  "Render the current buffer using its owning frame's light or dark palette."
  (when heroiclands-preview-mode
    (heroiclands-preview--send
     `(:type "render" :generation ,heroiclands-preview--generation
       :text ,(buffer-substring-no-properties (point-min) (point-max))
       :infobox ,(if heroiclands-preview-show-infobox t :false)
       :dark ,(if (eq (frame-parameter
                       (and (frame-live-p heroiclands-preview--frame)
                            heroiclands-preview--frame)
                       'background-mode) 'dark) t :false)))))

(defun heroiclands-preview--changed (&rest _)
  "Reset the idle render timer after an edit."
  (cl-incf heroiclands-preview--generation)
  (heroiclands-preview--send
   `(:type "invalidate" :generation ,heroiclands-preview--generation))
  (when heroiclands-preview--timer
    (cancel-timer heroiclands-preview--timer))
  (setq heroiclands-preview--timer
        (run-with-idle-timer heroiclands-preview-idle-delay nil
                             #'heroiclands-preview--idle (current-buffer))))

(defun heroiclands-preview--idle (buffer)
  "Render BUFFER if its preview remains active."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq heroiclands-preview--timer nil)
      (heroiclands-preview--render))))

(defun heroiclands-preview--event (event)
  "Handle one renderer EVENT for the current note buffer."
  (pcase (gethash "type" event)
    ("ready"
     (setq heroiclands-preview--ready t
           heroiclands-preview--url (gethash "url" event))
     (unless heroiclands-preview--opened
       (let ((browse-url-new-window-flag heroiclands-preview-new-window))
         (browse-url heroiclands-preview--url))
       (setq heroiclands-preview--opened t))
     (heroiclands-preview--render))
    ("error"
     (when (or (null (gethash "generation" event))
               (= (gethash "generation" event) heroiclands-preview--generation))
       (message "HeroicLands preview: %s" (gethash "message" event))))))

(defun heroiclands-preview--filter (process output)
  "Decode OUTPUT from PROCESS as newline-delimited JSON events."
  (when-let* ((buffer (process-get process 'note-buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq heroiclands-preview--pending
            (concat heroiclands-preview--pending output))
      (while (string-match "\n" heroiclands-preview--pending)
        (let ((line (substring heroiclands-preview--pending 0 (match-beginning 0))))
          (setq heroiclands-preview--pending
                (substring heroiclands-preview--pending (match-end 0)))
          (condition-case error
              (heroiclands-preview--event
               (json-parse-string line :object-type 'hash-table))
            (error (message "HeroicLands preview protocol: %s" error))))))))

(defun heroiclands-preview--sentinel (process _event)
  "Report an unexpected exit of PROCESS."
  (when-let* ((buffer (process-get process 'note-buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (and heroiclands-preview-mode
                 (eq process heroiclands-preview--process)
                 (not (process-live-p process)))
        (message "HeroicLands preview stopped; see %s"
                 (buffer-name heroiclands-preview--output))
        (heroiclands-preview-mode -1)))))

(defun heroiclands-preview--launch ()
  "Start this note's renderer."
  (let* ((root (expand-file-name
                (or (heroiclands--project-root)
                    (user-error "No content project contains this note"))))
         (script (expand-file-name "heroiclands-preview.mjs" heroiclands-directory))
         (output (or (and (buffer-live-p heroiclands-preview--output)
                          heroiclands-preview--output)
                     (generate-new-buffer " *HeroicLands preview*")))
         (command (list heroiclands-preview-node script
                        (expand-file-name heroiclands-server-directory)
                        root (expand-file-name buffer-file-name)))
         (process (make-process
                   :name "heroiclands-preview"
                   :buffer output
                   :stderr output
                   :command command
                   :connection-type 'pipe
                   :noquery t
                   :filter #'heroiclands-preview--filter
                   :sentinel #'heroiclands-preview--sentinel)))
    (process-put process 'note-buffer (current-buffer))
    (setq heroiclands-preview--process process
          heroiclands-preview--output output
          heroiclands-preview--pending ""
          heroiclands-preview--ready nil)))

(defun heroiclands-preview--stop ()
  "Release this buffer's timer and renderer."
  (when heroiclands-preview--timer
    (cancel-timer heroiclands-preview--timer)
    (setq heroiclands-preview--timer nil))
  (remove-hook 'after-change-functions #'heroiclands-preview--changed t)
  (remove-hook 'kill-buffer-hook #'heroiclands-preview--stop t)
  (when (process-live-p heroiclands-preview--process)
    (process-send-string heroiclands-preview--process "{\"type\":\"stop\"}\n")
    (run-at-time 1 nil
                 (lambda (process)
                   (when (process-live-p process) (delete-process process)))
                 heroiclands-preview--process))
  (setq heroiclands-preview--process nil
        heroiclands-preview--ready nil
        heroiclands-preview--url nil
        heroiclands-preview--opened nil
        heroiclands-preview--frame nil))

;;;###autoload
(define-minor-mode heroiclands-preview-mode
  "Preview this HeroicLands note in a browser window.

The current buffer is rendered after `heroiclands-preview-idle-delay'
seconds without typing.  The browser updates without navigating away.
Local infobox fields appear when enabled.  Errors leave the last good page
visible.  Use `heroiclands-preview-refresh' to render immediately.
Content comes from this buffer; the project current date is reread on render.
No content index or SQL engine is needed.

See Info node `(heroiclands)Live Preview'."
  :lighter " Preview"
  :group 'heroiclands-preview
  (if heroiclands-preview-mode
      (condition-case error
          (progn
            (unless (and buffer-file-name (bound-and-true-p heroiclands-mode))
              (user-error "Live preview needs a visiting HeroicLands note"))
            (unless (executable-find heroiclands-preview-node)
              (user-error "Node executable not found: %s" heroiclands-preview-node))
            (setq heroiclands-preview--generation 0
                  heroiclands-preview--frame (selected-frame))
            (heroiclands-preview--launch)
            (add-hook 'after-change-functions #'heroiclands-preview--changed nil t)
            (add-hook 'kill-buffer-hook #'heroiclands-preview--stop nil t))
        (error
         (heroiclands-preview-mode -1)
         (signal (car error) (cdr error))))
    (heroiclands-preview--stop)))

;;;###autoload
(defun heroiclands-preview-toggle ()
  "Toggle the current note's live browser preview.

See Info node `(heroiclands)Live Preview'."
  (interactive)
  (heroiclands-preview-mode (if heroiclands-preview-mode -1 1)))

;;;###autoload
(defun heroiclands-preview-refresh ()
  "Render the current buffer immediately with the active theme palette.

See Info node `(heroiclands)Live Preview'."
  (interactive)
  (unless heroiclands-preview-mode
    (user-error "Live preview is not active"))
  (when heroiclands-preview--timer
    (cancel-timer heroiclands-preview--timer)
    (setq heroiclands-preview--timer nil))
  (cl-incf heroiclands-preview--generation)
  (heroiclands-preview--render))

(defun heroiclands-preview--theme-changed (&rest _)
  "Render all active previews when the enabled theme changes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when heroiclands-preview-mode
        (heroiclands-preview-refresh)))))

(add-hook 'enable-theme-functions #'heroiclands-preview--theme-changed)
(add-hook 'disable-theme-functions #'heroiclands-preview--theme-changed)

(define-key heroiclands-prefix-map (kbd "p") #'heroiclands-preview-toggle)
(define-key heroiclands-prefix-map (kbd "P") #'heroiclands-preview-refresh)

(provide 'heroiclands-preview)
;;; heroiclands-preview.el ends here
