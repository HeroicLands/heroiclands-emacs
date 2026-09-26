;;; heroiclands-server-test.el --- Private index integration checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands-index)

(ert-deftest heroiclands-server-validates-private-index-after-project-clean ()
  (let* ((root (make-temp-file "heroiclands-index-project-" t))
         (editor (make-temp-file "heroiclands-index-editor-" t))
         (heroiclands-server-directory editor)
         (index (expand-file-name "cache/metadata.jsonl" editor))
         (manifest (expand-file-name "cache/metadata.json" editor))
         (generator (expand-file-name
                     "node_modules/@heroiclands/package-build/package.json" editor))
         (build (expand-file-name "build/content-index" root))
         (heroiclands-server--validity (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory index) t)
          (make-directory (file-name-directory generator) t)
          (make-directory build t)
          (with-temp-file generator (insert "{\"version\":\"22.12.3\"}"))
          (with-temp-file index (insert "{\"name\":\"Guide\"}\n"))
          (with-temp-file manifest
            (insert (json-encode
                     `((package . "thalorna")
                       (generatorVersion . "22.12.3")
                       (sha256 . ,(with-temp-buffer
                                    (insert-file-contents-literally index)
                                    (secure-hash 'sha256 (current-buffer))))))))
          (cl-letf (((symbol-function 'heroiclands-server-index-path)
                     (lambda (_root) index))
                    ((symbol-function 'heroiclands-project-package)
                     (lambda (_root) "thalorna")))
            (should (equal (heroiclands-server-index-file root) index))
            (delete-directory (expand-file-name "build" root) t)
            (should (equal (heroiclands-server-index-file root) index))
            (with-temp-file manifest
              (insert "{\"package\":\"thalorna\",\"generatorVersion\":\"22.12.3\",\"sha256\":\"wrong\"}"))
            (should-not (heroiclands-server-index-file root))))
      (delete-directory root t)
      (delete-directory editor t))))

(ert-deftest heroiclands-index-rebuild-runs-pinned-server-in-current-project ()
  (let* ((root (make-temp-file "heroiclands-index-current-" t))
         (foreign (make-temp-file "heroiclands-index-foreign-" t))
         (binary (expand-file-name "server" root))
         (marker (expand-file-name "rebuild-root" root)))
    (unwind-protect
        (progn
          (with-temp-file binary
            (insert (format "#!/bin/sh\npwd > %s\n"
                            (shell-quote-argument marker))))
          (set-file-modes binary #o755)
          (cl-letf (((symbol-function 'heroiclands--project-root)
                     (lambda () root))
                    ((symbol-function 'heroiclands-project-p)
                     (lambda (_directory) t))
                    ((symbol-function 'heroiclands-server-require-executable)
                     (lambda () binary)))
            (let ((default-directory foreign))
              (heroiclands-index-rebuild))
            (let ((process (get-process "heroiclands-index")))
              (should process)
              (while (process-live-p process)
                (accept-process-output process 0.1))
              (accept-process-output process 0.1))
            (should (file-exists-p marker))
            (with-temp-buffer
              (insert-file-contents marker)
              (should (equal (string-trim (buffer-string)) root)))
            (should-not (file-exists-p (expand-file-name "rebuild-root" foreign)))))
      (delete-directory root t)
      (delete-directory foreign t))))

;;; heroiclands-server-test.el ends here
