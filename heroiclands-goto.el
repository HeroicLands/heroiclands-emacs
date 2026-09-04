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

(defun heroiclands-goto--address-prefix-p (typed index)
  "Whether TYPED reads as the start of an address, per INDEX.

The test is the one an author would state: a known content type, then a
separator — `weapongear-', `being/', or the package-qualified
`sohl-weapongear-'.  Anything else is taken for a name, which is what makes
the two completion modes predictable rather than a guess about intent."
  (let* ((types (plist-get index :types))
         (package (plist-get index :package))
         (s (downcase typed))
         ;; A leading package segment is optional, and stripped before the
         ;; type is looked for — exactly as `readQualifier' does.
         (rest (if (and package (string-prefix-p (concat (downcase package) "-") s))
                   (substring s (1+ (length package)))
                 s)))
    (and (string-match "\\`\\([^-/]+\\)[-/]" rest)
         (gethash (match-string 1 rest) types)
         t)))

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
Rebuild the index with \\[heroiclands-index-rebuild] if a note is missing.

A link naming an unknown note, or an anchor the note does not declare, says
so and lists the anchors that do exist.

See Info node `(heroiclands)Following a Link'."
  (interactive)
  (let* ((link (or (heroiclands-goto-link-at-point)
                   (user-error "No wikilink at point")))
         (target (car link))
         (anchor (cdr link))
         (root (heroiclands-index--root))
         (files (or (heroiclands-index-files root)
                    (user-error "No content index built — run %s first"
                                (substitute-command-keys
                                 "\\[heroiclands-index-rebuild]"))))
         (record (gethash (heroiclands-goto--normalize target)
                          (heroiclands-goto--table files))))
    (unless record
      (user-error "No note addressed `%s' in this package's index" target))
    (let* ((file (plist-get record :file))
           ;; The index stores a path relative to the content root, which is
           ;; the portable form; the absolute one is composed here.
           (content (expand-file-name
                     (or (heroiclands-goto--content-dir root) "assets/content")
                     root))
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
  "The content tree ROOT declares, read from `package-build.config.yaml'.

Defaults to the conventional layout when the file names none."
  (let ((config (expand-file-name "package-build.config.yaml" root)))
    (when (file-readable-p config)
      (with-temp-buffer
        (insert-file-contents config)
        (goto-char (point-min))
        (when (re-search-forward "^paths:[ \t]*$" nil t)
          (let ((end (or (save-excursion (re-search-forward "^[^ \t\n#]" nil t)) (point-max))))
            (when (re-search-forward "^[ \t]+content:[ \t]*\\(.+?\\)[ \t]*$" end t)
              (string-trim (match-string 1) "[\"']" "[\"']"))))))))

;;;###autoload
(defun heroiclands-goto-back ()
  "Return to where the last \\[heroiclands-goto-follow] was invoked.

Uses the same marker stack as \\[xref-find-definitions], so the two compose.

See Info node `(heroiclands)Following a Link'."
  (interactive)
  (xref-go-back))


;;;; ------------------------------------------------------ completion

(defun heroiclands-goto--records (index)
  "Every record in INDEX, deduplicated by note."
  (let (seen out)
    (maphash (lambda (_k record)
               (let ((path (plist-get (plist-get record :file) :path)))
                 (unless (member path seen)
                   (push path seen)
                   (push record out))))
             (heroiclands-goto--table index))
    (nreverse out)))

(defconst heroiclands-goto-separator " — "
  "Separates an address from its readable name in a completion candidate.

The name rides in the candidate rather than in an annotation so that it is
*matchable*: a shortcode like `bctrncml' is not something anyone recalls, but
\"bactrian\" is.  `heroiclands-goto--exit' strips it again on insertion, so the
buffer only ever receives the address.  Same separator, and same reasoning, as
`heroiclands-find-by-key'.")

(defun heroiclands-goto--fold (s)
  "Reduce S to letters and digits, lowercased, for an is-this-the-same test."
  (replace-regexp-in-string "[^a-z0-9]" "" (downcase s)))

(defun heroiclands-goto--tag (display address)
  "DISPLAY, carrying ADDRESS as the thing to insert when it is chosen."
  (propertize display 'heroiclands-address address))

(defun heroiclands-goto--dim (text)
  "TEXT, faced as completion commentary."
  (propertize text 'face 'completions-annotations))

(defun heroiclands-goto--candidate (key name &optional ascii)
  "Render KEY with its readable NAME, when NAME says anything KEY does not.

The name half is faced as an annotation, so it reads as commentary even
though it is part of the string being matched.

ASCII is the index's `nameAscii' — NAME reduced to typeable characters.  It
is appended in parentheses only when it differs from NAME, so a name written
in the setting's orthography is reachable from a keyboard."
  (heroiclands-goto--tag
   (if (or (null name)
           (not (stringp name))
           (string-empty-p name)
           ;; A name that is only the key respelled adds nothing — an anchor
           ;; `dossier' titled "Dossier" is the common case.
           (equal (heroiclands-goto--fold name) (heroiclands-goto--fold key)))
       key
     (concat key
             (heroiclands-goto--dim
              (concat heroiclands-goto-separator name
                      (if (and (stringp ascii) (not (equal ascii name)))
                          (format " (%s)" ascii)
                        "")))))
   key))

(defun heroiclands-goto--name-candidates (record)
  "Completion candidates for RECORD: its name, and each of its aliases.

An alias is the name a reader is at least as likely to reach for as the
canonical one — `Killer Whale' for an orca — so it earns a candidate of its
own rather than being hidden behind the primary name.  An alias candidate
names where it leads (`[being -> Orca]'), so choosing one is never a guess
about which note is meant.

The typeable form leads in every case, so the candidate matches what a
keyboard produces; the address follows as commentary."
  (let* ((address (plist-get (plist-get record :address) :slug))
         (full (plist-get (plist-get record :name) :full))
         (ascii (or (plist-get record :nameAscii) full))
         (type (plist-get record :type))
         (aliases (append (plist-get record :aliasesAscii) nil))
         (out nil))
    (when (and address ascii)
      (push (heroiclands-goto--tag
             (concat ascii
                     (heroiclands-goto--dim
                      (concat heroiclands-goto-separator address
                              (if (and (stringp full) (not (equal full ascii)))
                                  (format " (%s)" full)
                                "")
                              (if type (format "  [%s]" type) ""))))
             address)
            out))
    (when address
      (dolist (alias aliases)
        (push (heroiclands-goto--tag
               (concat alias
                       (heroiclands-goto--dim
                        (concat heroiclands-goto-separator address
                                (format "  [%s%s]"
                                        (or type "")
                                        (if full (format " -> %s" full) "")))))
               address)
              out)))
    (nreverse out)))

(defun heroiclands-goto--address-of (candidate mode)
  "The address CANDIDATE names, in completion MODE.

Taken from the text property the candidate carries; the split is a fallback
for a completion front-end that hands back a bare string.  MODE says which
half the address is: `name' puts it after the separator, anything else
before it."
  (or (get-text-property 0 'heroiclands-address candidate)
      (let ((parts (split-string (substring-no-properties candidate)
                                 heroiclands-goto-separator)))
        (if (eq mode 'name)
            (car (split-string (or (cadr parts) "") " "))
          (car parts)))))

(defun heroiclands-goto--exit (start mode)
  "Return an exit function replacing the region from START with the address.

Completion inserts the whole candidate — which in either mode carries more
than the address, for the reader's benefit — and this puts the buffer back
to just the address, which is all a wikilink may contain.  MODE is passed to
`heroiclands-goto--address-of'."
  (lambda (candidate _status)
    (let ((address (heroiclands-goto--address-of candidate mode)))
      (delete-region start (point))
      (insert address))))

(defun heroiclands-goto-capf ()
  "Complete a wikilink from the content index, by address or by name.

Three modes, chosen by what has been typed:

- After a `#', the anchors the named note declares — exactly those, since
  the index holds its whole set.
- When the text reads as the start of an address — a known content type
  then a separator, as in `weapongear-' or `sohl-being/' — the addresses
  under it.
- Otherwise, the notes whose `nameAscii' matches, so a note is reachable by
  what it is called rather than by a shortcode nobody recalls.  Typing
  `[[' with nothing after it offers every note this way.

Either way only the address is inserted.  Returns nil away from a wikilink,
so it composes with the other completion sources.

Completion arms when `[[' is typed and disarms when the link closes, so
editing an existing link does not wake it.

See Info node `(heroiclands)Completion'."
  (when-let* (((heroiclands-goto--armed-p))
              (root (ignore-errors (heroiclands-index--root)))
              (files (heroiclands-index-files root))
              (open (save-excursion
                      (save-restriction
                        (narrow-to-region (line-beginning-position) (point))
                        (search-backward "[[" nil t)))))
    (progn
      (let* ((start (+ open 2))
             (typed (buffer-substring-no-properties start (point)))
             (index (heroiclands-goto--index files))
             (table (plist-get index :table))
             (hash (string-match "#" typed)))
        (cond
         ;; Anchors of the note the address names.
         (hash
          (let* ((address (substring typed 0 hash))
                 (record (gethash (heroiclands-goto--normalize address) table))
                 (anchors (append (plist-get record :anchors) nil))
                 (from (+ start hash 1)))
            (list from (point)
                  (mapcar (lambda (a)
                            (heroiclands-goto--candidate
                             (plist-get a :slug) (plist-get a :name)))
                          anchors)
                  :exit-function (heroiclands-goto--exit from 'anchor)
                  :exclusive 'no)))

         ;; A type and a separator: the author is spelling an address.
         ((heroiclands-goto--address-prefix-p typed index)
          (let (candidates)
            (maphash
             (lambda (key record)
               (push (heroiclands-goto--candidate
                      key
                      (plist-get (plist-get record :name) :full)
                      (plist-get record :nameAscii))
                     candidates))
             table)
            (list start (point) (nreverse candidates)
                  :exit-function (heroiclands-goto--exit start 'address)
                  :exclusive 'no)))

         ;; Anything else is a name.
         (t
          (let (seen candidates)
            (maphash
             (lambda (_key record)
               ;; The table holds each record twice, under its slug and its
               ;; canonical key; a note should be offered once.
               (let ((path (plist-get (plist-get record :file) :path)))
                 (unless (member path seen)
                   (push path seen)
                   (dolist (c (heroiclands-goto--name-candidates record))
                     (push c candidates)))))
             table)
            (list start (point)
                  (sort (nreverse candidates) #'string-lessp)
                  :exit-function (heroiclands-goto--exit start 'name)
                  :exclusive 'no))))))))

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
       (let ((path (plist-get (plist-get record :file) :path)))
         (unless (member path seen)
           (push path seen)
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

(defun heroiclands-goto--close-link ()
  "Canonicalize the wikilink just closed by typing `]]'.

Runs from `post-self-insert-hook'.  A link that already states its display
text is left alone — the author chose it.  Otherwise the target is resolved,
by address or by name, and the link is rewritten as
`[[<address>|<name.full>]]'.

Anything that does not resolve to exactly one note is an error, and so is an
anchor the note does not declare: the index knows the whole answer, so a link
that cannot work is reported where it was written rather than surviving to
fail in a build.

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
    (heroiclands-goto--disarm)
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
                  (insert replacement)))))))))))

;; Installed by `heroiclands-mode', not by a hook of its own: one mode
;; owns this buffer's behaviour, so there is one thing to turn off.

(define-key heroiclands-prefix-map (kbd ".") #'heroiclands-goto-follow)
(define-key heroiclands-prefix-map (kbd ",") #'heroiclands-goto-back)

(provide 'heroiclands-goto)
;;; heroiclands-goto.el ends here
