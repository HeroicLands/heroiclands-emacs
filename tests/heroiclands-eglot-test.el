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
         (heroiclands-server-directory (expand-file-name "editor" root)))
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
              (should (equal (heroiclands-eglot--contact) (list binary))))))
      (delete-directory root t))))

;;; heroiclands-eglot-test.el ends here
