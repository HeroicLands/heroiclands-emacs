;;; heroiclands.el --- The HeroicLands repo constellation -*- lexical-binding: t; -*-
;;
;; Author: Tom Rodriguez <tom@toastysailor.com>
;; Maintainer: Tom Rodriguez <tom@toastysailor.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience, wp
;; URL: https://github.com/HeroicLands/heroiclands-emacs
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you may redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  It is distributed WITHOUT ANY WARRANTY; without even the
;; implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the LICENSE file for details.
;;
;; One config for ~16 live repositories rather than a .dir-locals.el copied
;; into each. A directory is a HeroicLands content project when it contains
;; `package-build.config.yaml' — true of 7 of the 8 primary repos, and true
;; automatically for any new one.
;;
;;   C-c h h   jump to a repo in the constellation
;;   C-c h g   ripgrep across EVERY repo at once
;;   C-c h c   compile (pick an npm script for this project)
;;   C-c h b   build:types      C-c h t  test      C-c h l  lint
;;   C-c h m   find a content note by canonical key (uses the link manifests)

;;; Code:

(require 'project)
(require 'subr-x)
(require 'compile)
(require 'seq)

;; Declared rather than required: `info' is loaded on demand, and the only
;; use below is inside `with-eval-after-load'.
(defvar Info-directory-list)

;; Optional siblings — the `C-c h' map binds them when they are loaded.
(declare-function heroiclands-hbs-describe "heroiclands-hbs")
(declare-function heroiclands-hbs-refresh "heroiclands-hbs")
(declare-function heroiclands-dataview-clear "heroiclands-dataview")
(declare-function heroiclands-goto-capf "heroiclands-goto")
(declare-function heroiclands-goto--arm "heroiclands-goto")
(declare-function heroiclands-goto--close-link "heroiclands-goto")
(declare-function heroiclands-highlight-enable "heroiclands-highlight")
(declare-function heroiclands-highlight-disable "heroiclands-highlight")
(declare-function heroiclands-highlight-refresh "heroiclands-highlight")
(declare-function heroiclands-index-files "heroiclands-index")

(defgroup heroiclands nil "HeroicLands multi-repo workflow." :group 'tools)

(define-obsolete-variable-alias 'heroiclands-root
  'heroiclands-project-roots "0.2.0"
  "A single hard-coded directory was one person's layout, not a convention.")

(defcustom heroiclands-project-roots nil
  "Directories to search for HeroicLands content projects.

Each entry is searched as described in `heroiclands-projects':  a
directory that is itself a project is taken as one, and otherwise its
subdirectories are searched, to `heroiclands-project-search-depth'.

Unset --- the default --- means **search nowhere**.  Nothing about a
filesystem is guessed: not a conventional directory, and not the siblings
of the current checkout, since either would be this package asserting where
your repositories ought to live.

What that costs is bounded, and worth knowing precisely.  The project a
buffer belongs to is found by `project', not by this list, so the local
index still loads and local links still resolve.  What needs the list is
everything *across* projects: resolving a canonical
`<package>-<type>-<shortcode>' address into another package, and the
constellation commands.  Set it once to have those."
  :type '(repeat directory) :group 'heroiclands)

(defcustom heroiclands-project-search-depth 3
  "How far below a root in `heroiclands-project-roots' to search.

A bound is needed because a root may be large: searching stops descending
as soon as it finds a project, but a directory holding no projects at all
would otherwise be walked to the bottom.  Three levels covers a root
holding repositories, or holding groups of them, without ever walking a
whole home directory."
  :type 'integer :group 'heroiclands)


(defcustom heroiclands-markers
  '("package-build.config.yaml"
    "package-build.config.yml"
    "package-build.config.mjs")
  "Files whose presence marks a directory as a HeroicLands content project.

All three names package-build itself resolves, in the order it reports
them: YAML first, `.mjs' last — the escape hatch for a consumer that needs
to compute its configuration rather than declare it.  A project written
either of the other two ways is a project, and checking only for `.yaml'
would make it invisible to everything in this package.

Order settles nothing here: any one of them is enough.  Two of them in one
directory is an error, but it is package-build's error to report, not
this package's to guess at."
  :type '(repeat string) :group 'heroiclands)

;;;; ------------------------------------------------------------ discovery

(defun heroiclands--search-base ()
  "One directory to search across, for the commands that need a single one.

Ripgrep and find take a starting point rather than a set.  With one root
that is the root; with several it is their deepest common ancestor, which
is the smallest tree containing all of them."
  (let ((roots heroiclands-project-roots))
    (cond
     ((null roots) (or (heroiclands--project-root) default-directory))
     ((null (cdr roots)) (expand-file-name (car roots)))
     (t (let ((common (expand-file-name (car roots))))
          (dolist (r (cdr roots))
            (setq common (heroiclands--common-ancestor
                          common (expand-file-name r))))
          common)))))

(defun heroiclands--common-ancestor (a b)
  "The deepest directory containing both A and B."
  (let ((as (split-string (directory-file-name a) "/"))
        (bs (split-string (directory-file-name b) "/"))
        (out nil))
    (while (and as bs (equal (car as) (car bs)))
      (push (car as) out)
      (setq as (cdr as) bs (cdr bs)))
    (file-name-as-directory (mapconcat #'identity (nreverse out) "/"))))

(defun heroiclands--repo-p (dir)
  "Whether DIR is the root of a git checkout.

A linked worktree keeps `.git' as a *file* rather than a directory, and
counts: it is a checkout of the same content, and someone editing in one
should not find the package inert."
  (file-exists-p (expand-file-name ".git" dir)))

(defun heroiclands--search-root (root depth)
  "Content projects at or under ROOT, searching at most DEPTH levels down.

ROOT itself is tested first, and a directory that is a project is returned
without its subdirectories being searched: a project may well contain
checkouts of its own — worktrees under `.claude/worktrees', vendored
sources — and those are the same project, not more of them."
  (cond
   ((not (file-directory-p root)) nil)
   ((heroiclands-project-p root) (list (file-name-as-directory root)))
   ((<= depth 0) nil)
   (t
    (let (found)
      (dolist (d (ignore-errors (directory-files root t "\\`[^.]" t)))
        (when (file-directory-p d)
          (setq found (append found (heroiclands--search-root d (1- depth))))))
      found))))

(defun heroiclands--git-repos ()
  "Every git checkout among the searched roots.

Kept for the commands that want checkouts rather than content projects;
`heroiclands-projects' is the narrower list."
  (let (repos)
    (dolist (root heroiclands-project-roots)
      (dolist (d (ignore-errors
                   (directory-files (expand-file-name root) t "\\`[^.]" t)))
        (when (and (file-directory-p d) (heroiclands--repo-p d))
          (push (file-name-as-directory d) repos))))
    (nreverse (delete-dups repos))))

(defun heroiclands-project-p (dir)
  "Return non-nil when DIR is a HeroicLands content project.

That is: a git checkout carrying one of `heroiclands-markers'.  Both halves
are required — a bare directory of notes is not a project, and a checkout
of something else is not one either."
  (and (heroiclands--repo-p dir)
       (seq-some (lambda (marker)
                   (file-exists-p (expand-file-name marker dir)))
                 heroiclands-markers)))

(defun heroiclands--package-from-config (config)
  "Read `contentPackage\=' out of the configuration file CONFIG, or nil.

Both forms are read, with a difference that matters.  In YAML a bare word
is a string, so a quoted and an unquoted value mean the same thing and
both are taken.  In JavaScript a bare word is a *variable*, so only a
quoted string literal is taken from a `.mjs\=': that form exists precisely
so values can be computed, and reading an identifier as though it were the
package name would be inventing an answer.  A computed one yields nil, and
the project stays selectable by directory or by path like any other."
  (with-temp-buffer
    (insert-file-contents config)
    (goto-char (point-min))
    (if (string-match-p "\\.mjs\\'" config)
        ;; Quoted literal only.
        (when (re-search-forward
               "contentPackage[ \t]*:[ \t]*[\"']\\([^\"']+\\)[\"']" nil t)
          (match-string 1))
      (when (re-search-forward
             "^contentPackage:[ \t]*[\"']?\\([^ \t\n\"'#]+\\)[\"']?" nil t)
        (match-string 1)))))

(defun heroiclands-project-package (dir)
  "The content package the project at DIR publishes, or nil.

A directory name is not a package name, and in this constellation the two
have never once matched: `Song-of-Heroic-Lands-FoundryVTT' publishes
`sohl', `sohl-thalorna' publishes `thalorna', `HarnMaster-3-FoundryVTT'
publishes `hm3'.  A wikilink names the package, so anything selecting
projects by name has to know which is which.

This is the one fact worth taking from the configuration file rather than
from an index, because it is wanted *before* an index exists — which is
exactly when someone is saying which projects to load."
  (when-let* ((config (seq-find #'file-exists-p
                                (mapcar (lambda (m) (expand-file-name m dir))
                                        heroiclands-markers))))
    (heroiclands--package-from-config config)))

(defvar heroiclands--projects-cache nil
  "Cached result of `heroiclands-projects', with the roots it was found for.

Discovery walks the filesystem, and the answer changes only when someone
clones or removes a repository.  \\[heroiclands-refresh-projects] discards it.")

(defun heroiclands-projects (&optional refresh)
  "Every HeroicLands content project among the searched roots.

Each root in `heroiclands-project-roots' — or, when that is nil, the parent
of the current buffer's project — is searched as follows.  A root that is
itself a project is taken as one.  Otherwise its subdirectories are
searched, to `heroiclands-project-search-depth'.  **Searching stops at a
project**: its own subdirectories are not examined, because a checkout
inside a checkout is the same project rather than another one.

The result is cached; REFRESH, or \\[heroiclands-refresh-projects], recomputes it."
  (let ((roots heroiclands-project-roots))
    (when (or refresh (not (equal roots (car heroiclands--projects-cache))))
      (setq heroiclands--projects-cache
            (cons roots
                  (delete-dups
                   (mapcan (lambda (root)
                             (heroiclands--search-root
                              (expand-file-name root)
                              heroiclands-project-search-depth))
                           roots)))))
    (cdr heroiclands--projects-cache)))

;;;###autoload
(defun heroiclands-refresh-projects ()
  "Search the roots again, after cloning or removing a repository."
  (interactive)
  (let ((found (heroiclands-projects t)))
    (cond
     ((null heroiclands-project-roots)
      (message "No search roots — set `heroiclands-project-roots' to resolve %s"
               "links into other packages"))
     ((null found)
      (message "No content projects under %s"
               (mapconcat #'identity heroiclands-project-roots ", ")))
     (t
      (message "%d content project%s: %s"
               (length found) (if (= 1 (length found)) "" "s")
               (mapconcat (lambda (p)
                            (file-name-nondirectory (directory-file-name p)))
                          found ", "))))))

(defun heroiclands-active-repos (&optional months)
  "Repos with a commit in the last MONTHS (default 4)."
  (let ((cutoff (format "%d months ago" (or months 4))) active)
    (dolist (d (heroiclands--git-repos))
      (let ((out (string-trim
                  (shell-command-to-string
                   (format "git -C %s log -1 --since=%s --format=%%h 2>/dev/null"
                           (shell-quote-argument d)
                           (shell-quote-argument cutoff))))))
        (unless (string-empty-p out) (push d active))))
    (nreverse active)))

;;;###autoload
(defun heroiclands-switch-project ()
  "Jump to a repository in the constellation."
  (interactive)
  (let* ((repos (heroiclands--git-repos))
         (names (mapcar #'file-name-nondirectory repos))
         (pick  (completing-read "Repo: " names nil t))
         (dir   (seq-find (lambda (d) (equal (file-name-nondirectory d) pick)) repos)))
    (project-switch-project dir)))

;;;; --------------------------------------------------------------- search

;;;###autoload
(defun heroiclands-ripgrep-all (term)
  "Ripgrep TERM across EVERY repository at once.
This is the thing a per-repo editor window cannot do: one query over the
whole constellation, results in one buffer."
  (interactive "sSearch all repos: ")
  (require 'consult nil t)
  (if (fboundp 'consult-ripgrep)
      (consult-ripgrep (heroiclands--search-base) term)
    (let ((default-directory (heroiclands--search-base)))
      (compilation-start
       (format "rg --line-number --with-filename --color=never --glob '!node_modules' --glob '!build' %s ."
               (shell-quote-argument term))
       #'grep-mode))))

;;;###autoload
(defun heroiclands-find-note ()
  "Find a content note by filename across every repo's assets/content."
  (interactive)
  (require 'consult nil t)
  (if (fboundp 'consult-find)
      (consult-find (heroiclands--search-base))
    (call-interactively #'find-name-dired)))

;;;; -------------------------------------------------------------- compile

;; The project's diagnostics are `file:line:column: severity: message', which
;; is the GNU format compilation-mode already parses — so `M-g M-n' walks
;; content-build, tsc, eslint and vitest output with no extra configuration.

(defvar heroiclands-compile-commands
  '(("build:types  (tsc only, fast)" . "npm run build:types")
    ("test         (vitest)"         . "npm run test")
    ("lint"                          . "npm run lint")
    ("build        (full pipeline)"  . "npm run build")
    ("docs"                          . "npm run docs")
    ("build:db     (content packs)"  . "npm run build:db")
    ("e2e:fast"                      . "npm run e2e:fast")
    ("format:check"                  . "npm run format:check"))
  "npm scripts offered by `heroiclands-compile'.")

(defun heroiclands--project-root ()
  (or (when-let* ((p (project-current))) (project-root p))
      default-directory))

;;;###autoload
(defun heroiclands-compile ()
  "Pick an npm script and run it at the project root."
  (interactive)
  (let* ((pick (completing-read "Run: " (mapcar #'car heroiclands-compile-commands) nil t))
         (cmd  (cdr (assoc pick heroiclands-compile-commands)))
         (default-directory (heroiclands--project-root)))
    (compile cmd)))

(defmacro heroiclands--defcompile (name cmd doc)
  `(defun ,name ()
     ,doc (interactive)
     (let ((default-directory (heroiclands--project-root))) (compile ,cmd))))

(heroiclands--defcompile heroiclands-build-types "npm run build:types"
  "Typecheck with tsc — the authority the editor should defer to.")
(heroiclands--defcompile heroiclands-test "npm run test"
  "Run the vitest suite.")
(heroiclands--defcompile heroiclands-lint "npm run lint"
  "Run the lint chain.")

;; Scroll compilation output, stop at the first error, keep colours.
(setq compilation-scroll-output 'first-error
      compilation-always-kill t
      compilation-ask-about-save nil)
(add-hook 'compilation-filter-hook #'ansi-color-compilation-filter)

;;;; ------------------------------------------------- link-manifest completion

;; Every package publishes a manifest mapping a canonical key
;;   pkg-type-shortcode  ->  { path, name, uuid, doc }
;; Completing `[[' against the UNION of those manifests is the one thing no
;; per-repo tool has ever given this content tree.

(defvar heroiclands--manifest-cache nil)

(defun heroiclands--manifest-files ()
  "Every manifest JSON in the constellation."
  (let (files)
    (dolist (repo (heroiclands--git-repos))
      (dolist (sub '("assets/manifests" "build/manifests"))
        (let ((d (expand-file-name sub repo)))
          (when (file-directory-p d)
            (setq files (append files (directory-files d t "\\.json\\'")))))))
    files))

(defun heroiclands-load-manifests (&optional force)
  "Load and cache all link manifests. With FORCE, reread from disk.

The same canonical key appears in more than one manifest: a package
publishes its own into build/manifests/ and consumers vendor a copy into
assets/manifests/. Those copies drift, so the OWNING package's manifest
wins -- an entry whose key prefix matches the manifest's own `package'."
  (interactive "P")
  (when (or force (null heroiclands--manifest-cache))
    (let ((tbl (make-hash-table :test #'equal)))
      (dolist (f (heroiclands--manifest-files))
        (condition-case err
            (let* ((json (json-parse-string
                          (with-temp-buffer (insert-file-contents f) (buffer-string))
                          :object-type 'alist :array-type 'list))
                   (pkg  (alist-get 'package json))
                   (es   (alist-get 'entries json)))
              (dolist (e es)
                (let* ((key   (symbol-name (car e)))
                       (val   (cdr e))
                       (owns  (and pkg (string-prefix-p (concat pkg "-") key)))
                       (row   (list key (alist-get 'name val) (alist-get 'path val)
                                    (alist-get 'uuid val) pkg))
                       (prev  (gethash key tbl)))
                  ;; Take it when unseen, when this manifest owns the key, or
                  ;; when the previous row lacked a uuid and this one has one.
                  (when (or (null prev) owns (and (null (nth 3 prev)) (nth 3 row)))
                    (puthash key row tbl)))))
          (error (message "heroiclands: skipped manifest %s (%s)"
                          (file-name-nondirectory f) (error-message-string err)))))
      (setq heroiclands--manifest-cache
            (sort (hash-table-values tbl)
                  (lambda (a b) (string< (car a) (car b)))))))
  (when (called-interactively-p 'any)
    (message "%d unique keys from %d manifest files."
             (length heroiclands--manifest-cache)
             (length (heroiclands--manifest-files))))
  heroiclands--manifest-cache)

(defun heroiclands--annotate (key)
  (when-let* ((row (assoc key heroiclands--manifest-cache)))
    (concat "  " (or (nth 1 row) "") "  [" (or (nth 4 row) "?") "]")))

(defun heroiclands-manifest-capf ()
  "Complete a canonical key after `[['."
  (when (looking-back "\\[\\[\\([^]]*\\)" (line-beginning-position))
    (heroiclands-load-manifests)
    (list (match-beginning 1) (point)
          (mapcar #'car heroiclands--manifest-cache)
          :annotation-function #'heroiclands--annotate
          :exclusive 'no)))

;;;###autoload
(defun heroiclands-find-by-key ()
  "Pick a content note by canonical key and open it."
  (interactive)
  (heroiclands-load-manifests)
  (let* ((rows heroiclands--manifest-cache)
         (disp (mapcar (lambda (r) (format "%s — %s" (nth 0 r) (or (nth 1 r) ""))) rows))
         (pick (completing-read "Content note: " disp nil t))
         (key  (car (split-string pick " — ")))
         (row  (assoc key rows)))
    (if-let* ((needle (concat "\\`"
                              (regexp-quote
                               (car (last (split-string
                                           (string-trim-right (nth 2 row) "/") "/"))))
                              "\\.md\\'"))
              (hit (seq-some (lambda (p)
                               (car (ignore-errors
                                      (directory-files-recursively p needle))))
                             (heroiclands-projects))))
        (find-file hit)
      (message "Manifest key %s → path %s (no local .md found)" key (nth 2 row)))))

;;;; --------------------------------------------------------------- the mode

;; The buffer-local behaviour is a minor mode rather than a set of
;; `find-file-hook' functions, because that is what a minor mode is for and
;; because it is what makes the feature legible: `C-h m' describes it,
;; `M-x heroiclands-mode' toggles it, the lighter says when it is on, and a
;; buffer where it is unwanted can simply turn it off.
;;
;; The `C-c h' prefix stays *global* and is deliberately not part of this
;; mode: jumping between repositories and grepping across all of them are
;; things you do from anywhere, including from a buffer that belongs to no
;; project at all.  What the mode carries is only what is genuinely about
;; *this buffer* — the completions, and the wikilink machinery.

(defvar-local heroiclands--index-present nil
  "Whether a content index was found when this buffer's mode was enabled.

Read by the mode-line lighter, and recomputed by
`heroiclands-mode-note-index', which \\[heroiclands-index-rebuild] calls when
it finishes.  Cached rather than tested per redisplay: locating an index
walks the constellation, which is nothing once and far too much sixty times
a second.")

(defun heroiclands-mode-note-index ()
  "Re-check whether this buffer has a content index, and redraw the lighter."
  (setq heroiclands--index-present
        (and (fboundp 'heroiclands-index-files)
             (ignore-errors
               (consp (heroiclands-index-files (heroiclands--project-root))))))
  (force-mode-line-update))

(defun heroiclands--lighter ()
  "The mode-line lighter: \=` HL\=` normally, \=` HL?\=` with no index built.

The distinction is worth a character because it is the difference between
the mode working and half of it silently doing nothing.  The project marker
decides that this package is *relevant* here; the index decides which of it
is *live*, and only one of those is visible without being told."
  (if heroiclands--index-present
      " HL"
    (propertize " HL?" 'help-echo
                "No content index built — M-x heroiclands-index-rebuild"
                'face 'warning)))

(defvar heroiclands-mode-map (make-sparse-keymap)
  "Keymap for `heroiclands-mode'.

Deliberately near-empty: the `C-c h' prefix is global, because its commands
are about the constellation rather than about any one buffer.")

(defun heroiclands--mode-setup ()
  "Install this buffer's completions and wikilink machinery.

Each feature is guarded, so the mode works with whichever of the package's
files have been loaded rather than requiring all of them."
  (setq-local compile-command "npm run build:types")
  (when (fboundp 'heroiclands-manifest-capf)
    (add-hook 'completion-at-point-functions #'heroiclands-manifest-capf nil t))
  (when (fboundp 'heroiclands-goto-capf)
    (add-hook 'completion-at-point-functions #'heroiclands-goto-capf nil t))
  (when (fboundp 'heroiclands-goto--arm)
    (add-hook 'post-self-insert-hook #'heroiclands-goto--arm nil t))
  (when (fboundp 'heroiclands-goto--close-link)
    (add-hook 'post-self-insert-hook #'heroiclands-goto--close-link nil t))
  (when (fboundp 'heroiclands-highlight-enable)
    (heroiclands-highlight-enable))
  (heroiclands-mode-note-index)
  ;; Said once, on the way in, because the alternative is a buffer where
  ;; completion returns nothing and the cause is invisible.
  (unless heroiclands--index-present
    (message "%s: no content index built — %s"
             (buffer-name)
             (substitute-command-keys "\\[heroiclands-index-rebuild]"))))

(defun heroiclands--mode-teardown ()
  "Remove what `heroiclands--mode-setup' installed."
  (when (fboundp 'heroiclands-manifest-capf)
    (remove-hook 'completion-at-point-functions #'heroiclands-manifest-capf t))
  (when (fboundp 'heroiclands-goto-capf)
    (remove-hook 'completion-at-point-functions #'heroiclands-goto-capf t))
  (when (fboundp 'heroiclands-goto--arm)
    (remove-hook 'post-self-insert-hook #'heroiclands-goto--arm t))
  (when (fboundp 'heroiclands-goto--close-link)
    (remove-hook 'post-self-insert-hook #'heroiclands-goto--close-link t))
  (when (fboundp 'heroiclands-dataview-clear)
    (heroiclands-dataview-clear))
  (when (fboundp 'heroiclands-highlight-disable)
    (heroiclands-highlight-disable)))

;;;###autoload
(define-minor-mode heroiclands-mode
  "Author HeroicLands content notes.

Turns this buffer into one that knows the content tree: wikilink
completion by name or address, canonical rewriting when a link is closed,
and completion over the published link manifests.

\\<heroiclands-mode-map>
While the mode is on, in a content note:

  `[['   starts a wikilink and opens completion — by anchor, by address,
         or by name, chosen from what you type.
  `]]'   closes it and rewrites it into canonical form, or reports why it
         cannot: an unknown note, an ambiguous name, a missing anchor.

Both apply only to a link being *entered*; editing a settled link leaves
it alone.

The commands themselves live on the global `C-c h' prefix, which is not
part of this mode — see Info node `(heroiclands)Quick Reference'.  The
ones about this buffer are:

  \\[heroiclands-goto-follow]   follow the wikilink at point
  \\[heroiclands-goto-back]   jump back
  \\[heroiclands-dataview-mode]   toggle content-table previews
  \\[heroiclands-index-rebuild]   rebuild the content index
  \\[heroiclands-index-query]   query it with jq

Everything reads the content index, which nothing rebuilds for you.

See Info node `(heroiclands)Top' for the manual."
  :lighter (:eval (heroiclands--lighter))
  :keymap heroiclands-mode-map
  :group 'heroiclands
  (if heroiclands-mode
      (heroiclands--mode-setup)
    (heroiclands--mode-teardown)))

;; Let a note enable the mode from its own Local Variables block without
;; Emacs asking permission each time it is opened.
;;
;; `eval:' rather than the more obvious `mode: heroiclands', because a
;; `mode:' entry in an end-of-file block is taken as the *major* mode: Emacs
;; enables the minor mode and then leaves the buffer in `fundamental-mode',
;; silently losing markdown. `eval:' has neither problem.
;;
;; The first-line `-*-' form is not an option at all for a content note: the
;; comment would displace the `---' that must open the file, and both
;; gray-matter and package-build's own parser then read the note as having no
;; frontmatter — so the build skips it.
(dolist (form '((heroiclands-mode 1) (heroiclands-mode -1)))
  (add-to-list 'safe-local-eval-forms form))

(defun heroiclands-mode-maybe-enable ()
  "Turn on `heroiclands-mode' where it has something to do.

That is: a markdown buffer visiting a file inside a project that carries
any of `heroiclands-markers'."
  (when (and buffer-file-name
             (derived-mode-p 'markdown-mode 'gfm-mode)
             (when-let* ((root (heroiclands--project-root)))
               (heroiclands-project-p root)))
    (heroiclands-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-heroiclands-mode
  heroiclands-mode heroiclands-mode-maybe-enable
  :group 'heroiclands)

;;;; ------------------------------------------------------------ the manual

(defconst heroiclands-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "The directory this package was loaded from.

Resources that ship with the package — the Node renderer, the Info manual —
are found relative to this rather than to `user-emacs-directory', so the
package works wherever it is cloned.")

(defconst heroiclands-info-directory
  (expand-file-name "info" heroiclands-directory)
  "Where this package's Info manual is built.

Produced by `make info' from `doc/heroiclands.texi'; see the README.")

;; Registered so `C-h i' lists it beside every other manual: this is
;; documentation, and there is no reason to reach it a different way from
;; the way one reaches the Emacs manual.
(with-eval-after-load 'info
  (add-to-list 'Info-directory-list heroiclands-info-directory))

;;;###autoload
(defun heroiclands-help ()
  "Open the HeroicLands content-authoring manual.

Covers the content index, wikilink completion and normalization, content
tables, and what to do when something does not answer.  The same manual is
listed in `C-h i' under Emacs, and every command below documents itself in
`C-h f'.

See Info node `(heroiclands)Top'."
  (interactive)
  (info "(heroiclands)Top"))

;;;; --------------------------------------------------------------- keymap

(defvar heroiclands-prefix-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "h") #'heroiclands-switch-project)
    (define-key m (kbd "g") #'heroiclands-ripgrep-all)
    (define-key m (kbd "f") #'heroiclands-find-note)
    (define-key m (kbd "m") #'heroiclands-find-by-key)
    (define-key m (kbd "M") #'heroiclands-load-manifests)
    (define-key m (kbd "c") #'heroiclands-compile)
    (define-key m (kbd "b") #'heroiclands-build-types)
    (define-key m (kbd "t") #'heroiclands-test)
    (define-key m (kbd "l") #'heroiclands-lint)
    (define-key m (kbd "H") #'heroiclands-hbs-describe)
    (define-key m (kbd "R") #'heroiclands-hbs-refresh)
    (define-key m (kbd "?") #'heroiclands-help)
    m)
  "Prefix map bound to C-c h.")

(global-set-key (kbd "C-c h") heroiclands-prefix-map)

(provide 'heroiclands)
;;; heroiclands.el ends here
