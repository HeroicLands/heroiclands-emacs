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

(ert-deftest heroiclands-goto-closes-the-exact-server-selection ()
  (dolist (case '(("sohl-being-bctrncml" "Xerathian Bactrian Camel"
                  "thalorna-sohl-being-bctrncml"
                  "[[sohl-being-bctrncml|Xerathian Bactrian Camel]]")
                 ("sohl-none-being-bctrncml" "Bactrian Camel"
                  "sohl-none-being-bctrncml"
                  "[[sohl-none-being-bctrncml|Bactrian Camel]]")
                 ("being-orca" "Killer Whale" "sohl-note-being-orca"
                  "[[being-orca|Killer Whale]]")))
    (with-temp-buffer
      (insert "[[" (nth 0 case) "]]")
      (goto-char (point-max))
      (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2))
            heroiclands-goto--selected
            (list :address (nth 0 case) :canonical (nth 2 case)
                  :display (nth 1 case)
                  :entry (marker-position heroiclands-goto--entry)))
      (let ((last-command-event ?\]))
        (heroiclands-goto--close-link))
      (should (equal (buffer-string) (nth 3 case)))
      (should-not heroiclands-goto--selected)
      (should-not heroiclands-goto--entry))))

(ert-deftest heroiclands-goto-keeps-an-authored-display-and-a-settled-link ()
  (with-temp-buffer
    (insert "[[being-orca|The whale]]")
    (goto-char (point-max))
    (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2))
          heroiclands-goto--selected
          (list :address "being-orca" :canonical "sohl-note-being-orca"
                :display "Orca" :entry (+ (point-min) 2)))
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|The whale]]"))
    (setq heroiclands-goto--entry nil)
    (insert "x")
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|The whale]]x"))))

(ert-deftest heroiclands-goto-closes-electric-paired-brackets ()
  (with-temp-buffer
    (insert "[[]]")
    (goto-char (+ (point-min) 2))
    (let ((last-command-event ?\[))
      (heroiclands-goto--arm))
    (should (heroiclands-goto--armed-p))
    (insert "being-orca")
    (setq heroiclands-goto--selected
          (list :address "being-orca" :canonical "sohl-note-being-orca"
                :display "Orca"
                :entry (marker-position heroiclands-goto--entry)))
    (forward-char 2)
    (let ((last-command-event ?\]))
      (heroiclands-goto--close-link))
    (should (equal (buffer-string) "[[being-orca|Orca]]"))))

(ert-deftest heroiclands-goto-distinguishes-same-file-addresses ()
  (let ((table (make-hash-table :test #'equal)))
    (dolist (system '("sohl" "none"))
      (let ((record (list :address (list :canonical
                                         (format "thalorna-%s-being-bctrncml" system))
                          :name (list :full "Bactrian Camel")
                          :file (list :path "Camel.md"))))
        (puthash (plist-get (plist-get record :address) :canonical) record table)))
    (should (= (length (heroiclands-goto--name-matches
                        "Bactrian Camel" (list :table table)))
               2))))

(ert-deftest heroiclands-goto-asks-for-a-choice-on-ambiguous-name ()
  (let ((table (make-hash-table :test #'equal)))
    (dolist (system '("sohl" "none"))
      (let ((record (list :address (list :canonical
                                         (format "thalorna-%s-being-bctrncml" system)
                                         :slug "being-bctrncml")
                          :name (list :full "Bactrian Camel")
                          :file (list :path "Camel.md"))))
        (puthash (plist-get (plist-get record :address) :canonical) record table)))
    (with-temp-buffer
      (insert "[[Bactrian Camel]]")
      (goto-char (point-max))
      (setq heroiclands-goto--entry (copy-marker (+ (point-min) 2)))
      (cl-letf (((symbol-function 'heroiclands-index--root)
                 (lambda () default-directory))
                ((symbol-function 'heroiclands-index-files)
                 (lambda (_root) '("index.jsonl")))
                ((symbol-function 'heroiclands-goto--index)
                 (lambda (_files) (list :table table))))
        (let ((last-command-event ?\]))
          (should-error (heroiclands-goto--close-link) :type 'user-error))
        (should (equal (buffer-string) "[[Bactrian Camel]]"))
        (should-not heroiclands-goto--entry)))))

;;; heroiclands-goto-test.el ends here
