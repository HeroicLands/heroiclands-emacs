;;; heroiclands-preview-test.el --- Live preview controls -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands-preview)

(ert-deftest heroiclands-preview-debounces-edits-and-invalidates-work ()
  (with-temp-buffer
    (setq heroiclands-preview-mode t)
    (let (sent timers cancelled (rendered 0))
      (cl-letf (((symbol-function 'heroiclands-preview--send)
                 (lambda (message) (push message sent)))
                ((symbol-function 'run-with-idle-timer)
                 (lambda (_delay _repeat function buffer)
                   (let ((timer (cons function buffer)))
                     (push timer timers)
                     timer)))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled)))
                ((symbol-function 'heroiclands-preview--render)
                 (lambda (&optional _refresh) (cl-incf rendered))))
        (heroiclands-preview--changed)
        (heroiclands-preview--changed)
        (should (= heroiclands-preview--generation 2))
        (should (= (length sent) 2))
        (should (= (length cancelled) 1))
        (should (eq (car cancelled) (cadr timers)))
        (should (= rendered 0))
        (funcall (caar timers) (cdar timers))
        (should (= rendered 1))
        (should (null heroiclands-preview--timer))))))

(ert-deftest heroiclands-preview-ignores-stale-errors-and-opens-once ()
  (with-temp-buffer
    (setq heroiclands-preview-mode t
          heroiclands-preview--generation 2)
    (let (opened messages (rendered 0))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url opened)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)))
                ((symbol-function 'heroiclands-preview--render)
                 (lambda (&optional _refresh) (cl-incf rendered))))
        (heroiclands-preview--event
         (let ((event (make-hash-table :test 'equal)))
           (puthash "type" "ready" event)
           (puthash "url" "http://127.0.0.1:8123/" event)
           event))
        (heroiclands-preview--event
         (let ((event (make-hash-table :test 'equal)))
           (puthash "type" "ready" event)
           (puthash "url" "http://127.0.0.1:8123/" event)
           event))
        (dolist (generation '(1 2))
          (let ((event (make-hash-table :test 'equal)))
            (puthash "type" "error" event)
            (puthash "generation" generation event)
            (puthash "message" (format "failure %s" generation) event)
            (heroiclands-preview--event event)))
        (should (= (length opened) 1))
        (should (= rendered 2))
        (should (equal messages '("HeroicLands preview: failure 2")))))))

(ert-deftest heroiclands-preview-accepts-every-project-config-marker ()
  (dolist (marker heroiclands-markers)
    (let ((root (make-temp-file "heroiclands-preview-project-" t)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name ".git" root)
              (insert "gitdir: elsewhere\n"))
            (with-temp-file (expand-file-name marker root)
              (insert "contentPackage: fixture\n"))
            (should (heroiclands-project-p root)))
        (delete-directory root t)))))

(ert-deftest heroiclands-preview-stop-releases-timer-and-process ()
  (with-temp-buffer
    (setq heroiclands-preview--timer 'scheduled
          heroiclands-preview--process 'renderer
          heroiclands-preview--url "http://127.0.0.1:8123/")
    (let (cancelled sent fallback)
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (timer) (setq cancelled timer)))
                ((symbol-function 'process-live-p)
                 (lambda (process) (eq process 'renderer)))
                ((symbol-function 'process-send-string)
                 (lambda (_process text) (setq sent text)))
                ((symbol-function 'run-at-time)
                 (lambda (&rest args) (setq fallback args))))
        (heroiclands-preview--stop)
        (should (eq cancelled 'scheduled))
        (should (equal sent "{\"type\":\"stop\"}\n"))
        (should fallback)
        (should (null heroiclands-preview--process))
        (should (null heroiclands-preview--url))))))

(ert-deftest heroiclands-preview-refresh-restarts-on-the-same-port ()
  (with-temp-buffer
    (setq heroiclands-preview-mode t
          heroiclands-preview--url "http://127.0.0.1:8123/")
    (let (sent)
      (cl-letf (((symbol-function 'heroiclands-preview--send)
                 (lambda (message) (push message sent))))
        (heroiclands-preview-refresh)
        (should (= heroiclands-preview--restart-port 8123))
        (should (equal (plist-get (car sent) :type) "stop"))
        (should (equal (plist-get (cadr sent) :type) "invalidate"))))))

;;; heroiclands-preview-test.el ends here
