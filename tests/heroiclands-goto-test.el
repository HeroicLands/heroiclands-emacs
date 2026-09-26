;;; heroiclands-goto-test.el --- Wikilink destination checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands-goto)

(ert-deftest heroiclands-goto-follow-uses-the-records-owning-project ()
  (let* ((directory (make-temp-file "heroiclands-goto-" t))
         (local (expand-file-name "local" directory))
         (foreign (expand-file-name "foreign" directory))
         (local-index (expand-file-name "local.jsonl" directory))
         (foreign-index (expand-file-name "foreign.jsonl" directory))
         (heroiclands-goto--cache nil)
         opened)
    (unwind-protect
        (progn
          (make-directory local)
          (make-directory foreign)
          (with-temp-file foreign-index
            (insert (json-encode
                     '((package . "other")
                       (type . "lore")
                       (address . ((slug . "lore-beta")
                                   (canonical . "other-none-lore-beta")))
                       (file . ((path . "Foreign.md"))))) "\n"))
          (with-temp-file local-index
            (insert (json-encode
                     '((package . "local")
                       (type . "lore")
                       (address . ((slug . "lore-beta")
                                   (canonical . "local-none-lore-beta")))
                       (file . ((path . "Local.md"))))) "\n"))
          (with-temp-buffer
            (setq default-directory local)
            (cl-letf (((symbol-function 'heroiclands-index--root)
                       (lambda () local))
                      ((symbol-function 'heroiclands-index-sources)
                       (lambda (_root)
                         (list (cons foreign-index foreign)
                               (cons local-index local))))
                      ((symbol-function 'heroiclands-goto--content-dir)
                       (lambda (root) (if (equal root foreign) "notes" nil)))
                      ((symbol-function 'xref-push-marker-stack)
                       (lambda () nil))
                      ((symbol-function 'find-file)
                       (lambda (file) (push file opened))))
              (dolist (target '("other-none-lore-beta" "lore-beta"))
                (erase-buffer)
                (insert "[[" target "]]")
                (goto-char (+ (point-min) 3))
                (heroiclands-goto-follow))))
          (should (equal (nreverse opened)
                         (list (expand-file-name "Foreign.md" (expand-file-name "notes" foreign))
                               (expand-file-name "Local.md" (expand-file-name "assets/content" local))))))
      (delete-directory directory t))))

;;; heroiclands-goto-test.el ends here
