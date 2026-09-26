;;; heroiclands-eglot-test.el --- Eglot integration checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands-eglot)

(define-derived-mode markdown-mode text-mode "Markdown")

(ert-deftest heroiclands-eglot-starts-only-in-content-notes ()
  (let* ((root (make-temp-file "heroiclands-eglot-" t))
         (content (expand-file-name "assets/content" root))
         (inside (expand-file-name "Guide.md" content))
         (outside (expand-file-name "README.md" root))
         (started 0))
    (unwind-protect
        (progn
          (make-directory content t)
          (dolist (file (list inside outside))
            (with-temp-buffer
              (markdown-mode)
              (setq buffer-file-name file
                    default-directory root
                    heroiclands-mode t)
              (cl-letf (((symbol-function 'heroiclands--project-root)
                         (lambda () root))
                        ((symbol-function 'heroiclands-project-p)
                         (lambda (_directory) t))
                        ((symbol-function 'eglot-ensure)
                         (lambda () (cl-incf started))))
                (heroiclands-eglot--maybe-start)
                (if (equal file inside)
                    (progn
                      (should (= started 1))
                      (should (local-variable-p 'eglot-server-programs))
                      (should (eq (cdar eglot-server-programs)
                                  'heroiclands-eglot--contact)))
                  (should (= started 1))
                  (should-not (local-variable-p 'eglot-server-programs)))))))
      (delete-directory root t))))

(ert-deftest heroiclands-eglot-command-uses-pinned-server ()
  (let* ((root (make-temp-file "heroiclands-eglot-" t))
         (content (expand-file-name "assets/content" root))
         (binary (expand-file-name
                  "editor/node_modules/.bin/heroiclands-content-language-server" root))
         (heroiclands-server-directory (expand-file-name "editor" root))
         (heroiclands-index-projects nil))
    (unwind-protect
        (progn
          (make-directory content t)
          (make-directory (file-name-directory binary) t)
          (with-temp-file binary (insert "#!/bin/sh\n"))
          (set-file-modes binary #o755)
          (with-temp-buffer
            (markdown-mode)
            (setq buffer-file-name (expand-file-name "Guide.md" content)
                  default-directory root
                  heroiclands-mode t)
            (cl-letf (((symbol-function 'heroiclands--project-root)
                       (lambda () root))
                      ((symbol-function 'heroiclands-project-p)
                       (lambda (_directory) t)))
              (let ((contact (heroiclands-eglot--contact)))
                (should (equal (car contact) binary))
                (should (equal (funcall (plist-get (cdr contact)
                                                  :initializationOptions)
                                        nil)
                               '(:foreignRoots [])))))))
      (delete-directory root t))))

(ert-deftest heroiclands-eglot-selects-foreign-roots-without-an-index ()
  (let* ((directory (make-temp-file "heroiclands-eglot-projects-" t))
         (root (expand-file-name "local" directory))
         (foreign (expand-file-name "renamed-project" directory))
         (other (expand-file-name "other-project" directory))
         (content (expand-file-name "assets/content" root))
         (heroiclands-eglot-server-command '("server")))
    (unwind-protect
        (progn
          (mapc (lambda (path) (make-directory path t))
                (list content foreign other))
          (with-temp-buffer
            (markdown-mode)
            (setq buffer-file-name (expand-file-name "Guide.md" content)
                  default-directory root
                  heroiclands-mode t)
            (cl-letf (((symbol-function 'heroiclands--project-root)
                       (lambda () root))
                      ((symbol-function 'heroiclands-project-p)
                       (lambda (_directory) t))
                      ((symbol-function 'heroiclands-projects)
                       (lambda (&optional _refresh) (list root foreign other)))
                      ((symbol-function 'heroiclands-project-package)
                       (lambda (project)
                         (cond ((equal project foreign) "thalorna")
                               ((equal project other) "kethira")))))
              (dolist (case `((all ,foreign ,other)
                              (("thalorna") ,foreign)
                              ((,foreign) ,foreign)
                              (nil)))
                (let* ((heroiclands-index-projects (car case))
                       (contact (heroiclands-eglot--contact))
                       (options (funcall (plist-get (cdr contact)
                                                    :initializationOptions)
                                         nil)))
                  (should (equal (car contact) "server"))
                  (should (equal (append (plist-get options :foreignRoots) nil)
                                 (mapcar #'file-truename (cdr case)))))))))
      (delete-directory directory t))))

;;; heroiclands-eglot-test.el ends here
