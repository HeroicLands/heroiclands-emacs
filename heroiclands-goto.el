;;; heroiclands-goto.el --- Follow a wikilink to the note it names -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 Tom Rodriguez
;;
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This program is free software: you may redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  It is distributed WITHOUT ANY WARRANTY; without even the
;; implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the LICENSE file for details.
;;
;; The content index (`heroiclands-index.el') states every note's address and
;; every `{#slug}' anchor it declares, each with the line it sits on.  That is
;; enough to resolve a wikilink by lookup rather than by searching the tree, so
;; `[[being-aurochs#dossier]]' can open the file *at the heading*.
;;
;;   C-c h .   follow the wikilink at point
;;   C-c h ,   jump back
;;
;; A link whose note is unknown, or whose anchor the note does not declare,
;; says so instead of opening something approximate — the index knows the
;; note's whole anchor set, so "that anchor does not exist" is a fact here, not
;; a guess.
;;
;;; Code:

(require 'heroiclands)
(require 'heroiclands-index)
(require 'subr-x)
(require 'seq)
(require 'xref)

(defgroup heroiclands-goto nil
  "Following wikilinks between content notes."
  :group 'heroiclands)

(defvar heroiclands-goto--cache nil
  "Cons of (KEY . TABLE), where KEY identifies the index file it was read from.

TABLE maps a normalized address to the record's parsed plist.  Rebuilt when
the index file changes, so following a link after a rebuild sees new notes.")

(defun heroiclands-goto--index-key (files)
  "A cache key for FILES that changes whenever any of their contents might have."
  (mapcar (lambda (file)
            (let ((attrs (file-attributes file)))
              (list file
                    (file-attribute-size attrs)
                    (file-attribute-modification-time attrs))))
          (if (listp files) files (list files))))

(defun heroiclands-goto--normalize (target)
  "Normalize TARGET to the form the index stores.

Addresses are lowercased, and `type/shortcode' is the same address as
`type-shortcode' — `readQualifier' accepts both — so the slash form is
folded to the hyphen one before lookup."
  (let ((s (downcase (string-trim target))))
    ;; Only the LAST slash separates a type from a shortcode.
    (if (string-match "\\`\\(.*\\)/\\([^/]+\\)\\'" s)
        (concat (match-string 1 s) "-" (match-string 2 s))
      s)))

(defun heroiclands-goto--read-index (file table types packages)
  "Read one JSON Lines index FILE into TABLE and TYPES.

Returns the package it declares, or nil.  Every record is filed under both
its bare `type-shortcode' slug and its canonical `package-type-shortcode'
key, so a link resolves whichever form it was written in."
  (let ((package nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (unless (string-empty-p line)
            (let* ((record (json-parse-string line :object-type 'plist
                                              :null-object nil
                                              :false-object nil))
                   (address (plist-get record :address))
                   (type (plist-get record :type)))
              (when type (puthash (downcase type) t types))
              (when-let* ((pkg (plist-get record :package)))
                (puthash (downcase pkg) t packages)
                (unless package (setq package pkg)))
              (when address
                (setq record (plist-put record :owner-index file))
                (puthash (plist-get address :slug) record table)
                (puthash (plist-get address :canonical) record table)))))
        (forward-line 1)))
    package))

(defun heroiclands-goto--index (files)
  "Read FILES into a plist describing the combined index, cached by file state.

`:table' maps every address to its record, `:types' is the set of content
types, `:packages' is the set of packages actually held, and `:package' is
the one this project compiles as.

FILES may be one path or several.  Several is the ordinary case: a wikilink
may name a note in another package by its canonical
`<package>-<type>-<shortcode>' address, and resolving one means holding that
package's index too — see `heroiclands-index-projects'.  The **last** file
wins a collision, and `heroiclands-index-files' puts this project's own
index last, so a bare slug published by two packages means the local note."
  (let ((key (heroiclands-goto--index-key files))
        (files (if (listp files) files (list files))))
    (unless (equal key (car heroiclands-goto--cache))
      (let ((table (make-hash-table :test #'equal))
            (types (make-hash-table :test #'equal))
            (packages (make-hash-table :test #'equal))
            (package nil))
        (dolist (file files)
          (when (file-readable-p file)
            ;; The local index is read last, so its package is the one the
            ;; address/name mode test should use.
            (setq package (or (heroiclands-goto--read-index
                               file table types packages)
                              package))))
        (setq heroiclands-goto--cache
              (cons key (list :table table :types types
                              :packages packages :package package)))))
    (cdr heroiclands-goto--cache)))

(defun heroiclands-goto--table (files)
  "The address → record table of the combined index in FILES."
  (plist-get (heroiclands-goto--index files) :table))

(defun heroiclands-goto-link-at-point ()
  "The wikilink target at point, or nil.

Returns (TARGET . ANCHOR), with the display half after `|' discarded and
ANCHOR nil when the link names none."
  (save-excursion
    (let ((pos (point)) start end)
      ;; A wikilink cannot span lines, so search within this one.
      (save-restriction
        (narrow-to-region (line-beginning-position) (line-end-position))
        (goto-char pos)
        (when (and (setq start (search-backward "[[" nil t))
                   (goto-char start)
                   (setq end (search-forward "]]" nil t))
                   (>= end pos))
          (let* ((raw (buffer-substring-no-properties (+ start 2) (- end 2)))
                 ;; `[[target|Display]]' — the display half is not an address.
                 (target (car (split-string raw "|")))
                 (hash (string-match "#" target)))
            (if hash
                (cons (substring target 0 hash) (substring target (1+ hash)))
              (cons target nil))))))))

;;;###autoload
(defun heroiclands-goto-follow ()
  "Open the note the wikilink at point names, at its anchor when it has one.

Resolves through the content index, so it is a lookup rather than a search.
Refresh the index with \\[heroiclands-index-rebuild] if a note is missing.
Package-qualified links open a note under its owning project's content tree.

A link naming an unknown note, or an anchor the note does not declare, says
so and lists the anchors that do exist.

See Info node `(heroiclands)Following a Link'."
  (interactive)
  (let* ((link (or (heroiclands-goto-link-at-point)
                   (user-error "No wikilink at point")))
         (target (car link))
         (anchor (cdr link))
         (root (heroiclands-index--root))
         (sources (or (heroiclands-index-sources root)
                    (user-error "No content index built — run %s first"
                                (substitute-command-keys
                                 "\\[heroiclands-index-rebuild]"))))
         (files (mapcar #'car sources))
         (record (gethash (heroiclands-goto--normalize target)
                          (heroiclands-goto--table files))))
    (unless record
      (user-error "No note addressed `%s' in the selected content indexes" target))
    (let* ((file (plist-get record :file))
           (owner (or (cdr (assoc (plist-get record :owner-index) sources))
                      (user-error "No project owns the index record for `%s'" target)))
           ;; The index stores a path relative to the content root, which is
           ;; the portable form; the absolute one is composed here.
           (content (expand-file-name
                     (or (heroiclands-goto--content-dir owner) "assets/content")
                     owner))
           (full (expand-file-name (plist-get file :path) content))
           (anchors (append (plist-get record :anchors) nil))
           (hit (and anchor
                     (seq-find (lambda (a)
                                 (equal (downcase (plist-get a :slug))
                                        (downcase anchor)))
                               anchors))))
      (when (and anchor (not hit))
        ;; The index holds the note's whole anchor set, so this is a fact
        ;; rather than a failure to find something.
        (user-error "`%s' declares no anchor `%s' (it has: %s)"
                    target anchor
                    (if anchors
                        (mapconcat (lambda (a) (plist-get a :slug)) anchors ", ")
                      "none")))
      (xref-push-marker-stack)
      (find-file full)
      (when hit
        (goto-char (point-min))
        (forward-line (1- (plist-get hit :line)))
        (recenter))
      (message "%s%s" (plist-get file :path)
               (if hit (format " :%d  %s" (plist-get hit :line)
                               (plist-get hit :name))
                 "")))))

(defun heroiclands-goto--content-dir (root)
  "The content tree ROOT declares, or nil to take the conventional layout.

Reads `paths.content' from whichever of `heroiclands-markers' ROOT carries.
Only the YAML forms are read: a `.mjs' configuration computes its values by
running code, and guessing at them with a regexp would be worse than taking
the default, so that form falls through to the caller's fallback."
  (seq-some
   (lambda (marker)
     (and (string-match-p "\\.ya?ml\\'" marker)
          (let ((config (expand-file-name marker root)))
            (when (file-readable-p config)
              (with-temp-buffer
                (insert-file-contents config)
                (goto-char (point-min))
                (when (re-search-forward "^paths:[ \t]*$" nil t)
                  (let ((end (or (save-excursion (re-search-forward "^[^ \t\n#]" nil t))
                                 (point-max))))
                    (when (re-search-forward "^[ \t]+content:[ \t]*\\(.+?\\)[ \t]*$" end t)
                      (string-trim (match-string 1) "[\"']" "[\"']")))))))))
   heroiclands-markers))

;;;###autoload
(defun heroiclands-goto-back ()
  "Return to where the last \\[heroiclands-goto-follow] was invoked.

Uses the same marker stack as \\[xref-find-definitions], so the two compose.

See Info node `(heroiclands)Following a Link'."
  (interactive)
  (xref-go-back))


(defun heroiclands-goto--fold (s)
  "Reduce S to letters and digits, lowercased, for an is-this-the-same test."
  (replace-regexp-in-string "[^a-z0-9]" "" (downcase s)))

;;;; --------------------------------------------- when the machinery is live

(defvar-local heroiclands-goto--warned-no-index nil
  "Whether this buffer has already been told there is no content index.

Once, not once per link: a note being drafted before its index exists would
otherwise say it on every closing bracket.")

(defvar-local heroiclands-goto--entry nil
  "Marker just after a `[[' the author has typed, or nil.

Completion and normalization are deliberately confined to a link *being
entered*: they arm when `[[' is typed and disarm when the link is closed.
Going back to an existing link and editing it does not wake them again, so a
link that was settled stays settled.

The state has to be tracked rather than read off the buffer, because
`electric-pair-mode' closes the brackets as soon as they are opened — typing
`[[' yields `[[]]'.  There is therefore no such thing as a textually
unterminated wikilink to test for.")

(defvar-local heroiclands-goto--selected nil
  "Server completion item chosen for the link currently being entered.")

(defun heroiclands-goto--remember-selection (item typed)
  "Remember the exact target of the server completion ITEM for TYPED text."
  (when-let* (((heroiclands-goto--armed-p))
              (data (plist-get item :data))
              (address (plist-get (plist-get item :textEdit) :newText))
              (canonical (plist-get data :address))
              (display (plist-get data :display)))
    (setq heroiclands-goto--selected
          (list :address address :canonical canonical :display display
                :typed typed :entry (marker-position heroiclands-goto--entry)))))

(defun heroiclands-goto--disarm ()
  "Forget the link being entered."
  (when (markerp heroiclands-goto--entry)
    (set-marker heroiclands-goto--entry nil))
  (setq heroiclands-goto--entry nil))

(defun heroiclands-goto--arm ()
  "Note that a `[[' has just been typed, from `post-self-insert-hook'."
  (when (and (eq last-command-event ?\[)
             (>= (point) 3)
             (equal "[[" (buffer-substring-no-properties (- (point) 2) (point))))
    (heroiclands-goto--disarm)
    (setq heroiclands-goto--selected nil)
    ;; Insertion type nil: `electric-pair-mode' inserts the closing `]]'
    ;; at this very position, and a marker that advanced past it would sit
    ;; ahead of point and never look armed.
    (setq heroiclands-goto--entry (copy-marker (point)))))

(defun heroiclands-goto--armed-p ()
  "Whether point is inside the link that was armed by typing `[['."
  (and (markerp heroiclands-goto--entry)
       (marker-position heroiclands-goto--entry)
       (eq (marker-buffer heroiclands-goto--entry) (current-buffer))
       (>= (point) heroiclands-goto--entry)
       ;; A wikilink does not span lines, and leaving the line abandons it.
       (= (line-number-at-pos (point))
          (line-number-at-pos heroiclands-goto--entry))
       ;; Once the closing brackets are behind point the link is finished,
       ;; even though `electric-pair-mode' put them there from the start.
       (not (save-excursion
              (search-backward "]]" heroiclands-goto--entry t)))))

;;;; ------------------------------------------- closing a link canonically

(defcustom heroiclands-goto-canonicalize-on-close t
  "Whether typing `]]' rewrites the link it closes into canonical form.

With this on, `[[Aurochs]]' becomes `[[being-aurochs|Aurochs]]' the moment it
is closed, and a link naming no note — or naming several — raises an error
instead of being left to fail at build time.  Set it to nil to type links
without that check."
  :type 'boolean :group 'heroiclands-goto)

(defun heroiclands-goto--name-matches (text index)
  "Notes TEXT names, as a list of (RECORD . DISPLAY).

DISPLAY is the authored text that matched — the note's `name.full', or the
alias itself when TEXT named one.  An author who wrote a sobriquet meant that
sobriquet, so normalization keeps their wording rather than replacing it with
the canonical name.

Every comparison is on folded characters, so case, punctuation and the
difference between an authored name and its ASCII form all stop mattering."
  (let ((want (heroiclands-goto--fold text))
        (seen nil)
        (hits nil))
    (maphash
     (lambda (_key record)
       (let ((address (plist-get (plist-get record :address) :canonical)))
         (unless (member address seen)
           (push address seen)
           (let* ((full (plist-get (plist-get record :name) :full))
                  (ascii (plist-get record :nameAscii))
                  ;; Authored aliases and their ASCII forms are matched
                  ;; together; the authored one is what gets displayed.
                  (authored (append (plist-get (plist-get record :name) :aliases) nil))
                  (folded (append (plist-get record :aliasesAscii) nil))
                  (match nil))
             (when (or (and (stringp full) (equal (heroiclands-goto--fold full) want))
                       (and (stringp ascii) (equal (heroiclands-goto--fold ascii) want)))
               (setq match full))
             (unless match
               ;; An ASCII alias stands in for the authored one at the same
               ;; index; where they have drifted, the authored text still wins
               ;; because it is what the author would want to read.
               (let ((all (append authored folded)))
                 (setq match
                       (seq-find (lambda (a)
                                   (and (stringp a)
                                        (equal (heroiclands-goto--fold a) want)))
                                 all)))
               (when match
                 ;; Prefer the authored spelling of whatever matched.
                 (let ((i (seq-position folded match)))
                   (when (and i (nth i authored)) (setq match (nth i authored))))))
             (when match (push (cons record match) hits))))))
     (plist-get index :table))
    hits))

(defun heroiclands-goto--apply-selection (selected entry)
  "Close the exact server-selected target in SELECTED, armed at ENTRY.

Return non-nil when the selection belongs to this link.  The server supplied
both the shortest unambiguous Address and its display name."
  (when (and selected (equal entry (plist-get selected :entry)))
    (when-let* ((open (save-excursion
                        (save-restriction
                          (narrow-to-region (line-beginning-position) (point))
                          (search-backward "[[" nil t))))
                (raw (buffer-substring-no-properties (+ open 2) (- (point) 2)))
                (address (plist-get selected :address))
                (display (plist-get selected :display)))
      (let* ((hash (string-search "#" raw))
             (pipe (string-search "|" raw))
             (end (min (or hash (length raw)) (or pipe (length raw))))
             (target (substring raw 0 end)))
        (when (equal target address)
          (unless pipe
            (delete-region open (point))
            (insert (format "[[%s|%s]]" raw display)))
          t)))))

(defun heroiclands-goto--close-link ()
  "Canonicalize the wikilink just closed by typing `]]'.

Runs from `post-self-insert-hook'.  A link that already states its display
text is left alone.  A selected server item supplies the exact Address and
display name; otherwise the target is resolved from the available indexes.

An unknown or ambiguous target is reported at the link.  A missing anchor
is reported when the note's index is available.

See Info node `(heroiclands)Normalization'."
  (when (and heroiclands-goto-canonicalize-on-close
             (eq last-command-event ?\])
             (>= (point) 4)
             (equal "]]" (buffer-substring-no-properties (- (point) 2) (point)))
             ;; Only a link this session watched being typed. Re-closing an
             ;; old link while editing it is not an invitation to rewrite it.
             (markerp heroiclands-goto--entry)
             (marker-position heroiclands-goto--entry)
             (eq (marker-buffer heroiclands-goto--entry) (current-buffer))
             (>= (point) heroiclands-goto--entry))
    ;; The link is closed now either way — an error below must not leave the
    ;; machinery armed and fire again on the next keystroke.
    (let ((entry (marker-position heroiclands-goto--entry))
          (selected heroiclands-goto--selected))
      (heroiclands-goto--disarm)
      (setq heroiclands-goto--selected nil)
      (unless (heroiclands-goto--apply-selection selected entry)
	;; Silence here would be the worst outcome available: the author typed
	;; `]]' expecting the link to be canonicalized and checked, and would get
	;; neither with nothing to say why. Said once per buffer rather than
	;; raised — a link that cannot be checked is not itself an error, and
	;; erroring on every close while drafting would be worse than saying
	;; nothing at all.
	(when (and (ignore-errors (heroiclands-index--root))
		   (null (ignore-errors
			   (heroiclands-index-files (heroiclands-index--root))))
		   (not heroiclands-goto--warned-no-index))
	  (setq heroiclands-goto--warned-no-index t)
	  (message "No content index — link left as typed, and not checked (%s)"
		   (substitute-command-keys "\\[heroiclands-index-rebuild]")))
	(when-let* ((root (ignore-errors (heroiclands-index--root)))
                    (files (heroiclands-index-files root))
                    (open (save-excursion
                            (save-restriction
                              (narrow-to-region (line-beginning-position) (point))
                              (search-backward "[[" nil t))))
                    (raw (buffer-substring-no-properties (+ open 2) (- (point) 2))))
	  ;; An author-chosen display half is not ours to replace.
	  (unless (or (string-search "|" raw) (string-empty-p (string-trim raw)))
            (let* ((index (heroiclands-goto--index files))
		   (table (plist-get index :table))
		   (hash (string-search "#" raw))
		   (target (if hash (substring raw 0 hash) raw))
		   (anchor (and hash (substring raw (1+ hash))))
		   (direct (gethash (heroiclands-goto--normalize target) table))
		   ;; A direct address hit displays the note's own name; a name or
		   ;; alias hit displays the words the author actually typed.
		   (hits (if direct
                             (list (cons direct
					 (plist-get (plist-get direct :name) :full)))
			   (heroiclands-goto--name-matches target index))))
              (cond
               ((null hits)
		(user-error "No note named or addressed `%s'" target))
               ((cdr hits)
		(user-error "`%s' names %d notes (%s) — say which"
                            target (length hits)
                            (string-join
                             (seq-take (mapcar (lambda (h)
						 (plist-get (plist-get (car h) :address)
                                                            :slug))
                                               hits)
                                       4)
                             ", ")))
               (t
		(let* ((record (car (car hits)))
                       (address (plist-get (plist-get record :address) :slug))
                       (full (or (cdr (car hits))
				 (plist-get (plist-get record :name) :full)
				 address))
                       (anchors (append (plist-get record :anchors) nil)))
		  (when anchor
                    (unless (seq-find (lambda (a)
					(equal (downcase (plist-get a :slug))
                                               (downcase anchor)))
                                      anchors)
                      (user-error "`%s' declares no anchor `%s' (it has: %s)"
				  address anchor
				  (if anchors
                                      (mapconcat (lambda (a) (plist-get a :slug))
						 anchors ", ")
                                    "none"))))
		  (let ((replacement (format "[[%s%s|%s]]"
                                             address
                                             (if anchor (concat "#" anchor) "")
                                             full)))
                    (unless (equal replacement
				   (buffer-substring-no-properties open (point)))
                      (delete-region open (point))
                      (insert replacement)))))))))))))

;; Installed by `heroiclands-mode', not by a hook of its own: one mode
;; owns this buffer's behaviour, so there is one thing to turn off.

(define-key heroiclands-prefix-map (kbd ".") #'heroiclands-goto-follow)
(define-key heroiclands-prefix-map (kbd ",") #'heroiclands-goto-back)

(provide 'heroiclands-goto)
;;; heroiclands-goto.el ends here
