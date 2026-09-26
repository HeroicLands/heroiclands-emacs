;;; heroiclands-project-test.el --- Repository discovery checks -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'heroiclands)

(ert-deftest heroiclands-switch-project-includes-a-repository-root ()
  (let* ((directory (make-temp-file "heroiclands-projects-" t))
         (direct (expand-file-name "direct" directory))
         (group (expand-file-name "group" directory))
         (child (expand-file-name "child" group))
         (heroiclands-project-roots (list direct group))
         selected)
    (unwind-protect
        (progn
          (dolist (repo (list direct child))
            (make-directory repo t)
            (with-temp-file (expand-file-name ".git" repo)
              (insert "gitdir: elsewhere\n")))
          (should (equal (heroiclands--git-repos)
                         (list (file-name-as-directory direct)
                               (file-name-as-directory child))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt candidates &rest _args)
                       (should (equal candidates '("direct" "child")))
                       "direct"))
                    ((symbol-function 'project-switch-project)
                     (lambda (directory) (setq selected directory))))
            (heroiclands-switch-project))
          (should (equal selected (file-name-as-directory direct))))
      (delete-directory directory t))))

;;; heroiclands-project-test.el ends here
