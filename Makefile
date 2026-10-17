# heroiclands-emacs

EMACS ?= emacs
MAKEINFO ?= makeinfo

LISP := heroiclands.el heroiclands-hbs.el heroiclands-preview.el heroiclands-dataview.el \
        heroiclands-server.el heroiclands-index.el heroiclands-goto.el heroiclands-highlight.el \
        heroiclands-eglot.el heroiclands-authoring.el

.PHONY: all info compile check check-preview check-hooks hooks clean

all: info

## Build the Info manual, which `C-c h ?' and `C-h i' both read.
info: info/heroiclands.info

info/heroiclands.info: doc/heroiclands.texi
	@mkdir -p info
	$(MAKEINFO) --no-split -o $@ $<

## Byte-compile, treating warnings as failures — the same as CI does.
##
## Local and CI agreed on everything except this, so a warning could be seen
## and walked past here and then fail the pull request. In Emacs Lisp a
## warning is nearly always a real defect: a free variable is a missing
## `require', an unknown function a typo, and a stray quote a docstring that
## silently ended early. Three such have reached CI already.
compile:
	$(EMACS) -Q --batch -L . \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(LISP)

## Compile current sources before loading them in a clean Emacs.
##
## The eval form is kept on ONE line deliberately: a `\'-continuation inside a
## quoted argument is passed through to Emacs by some makes, which then reads a
## bare backslash as a variable and fails with `void-variable \'.
check: compile
	$(EMACS) -Q --batch -L . --eval '(mapc (lambda (f) (require (intern f))) (list "heroiclands" "heroiclands-hbs" "heroiclands-preview" "heroiclands-dataview" "heroiclands-server" "heroiclands-index" "heroiclands-goto" "heroiclands-highlight" "heroiclands-eglot" "heroiclands-authoring"))' --eval '(message "all features load")'
	$(EMACS) -Q --batch -L . -l tests/heroiclands-eglot-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-authoring-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-goto-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-project-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-server-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-highlight-test.el -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch -L . -l tests/heroiclands-preview-test.el -f ert-run-tests-batch-and-exit

check-preview:
	node --test tests/preview-browser.mjs

## Activate the canonical hooks in this clone and its linked worktrees.
## The relative path resolves against each worktree's own checkout.
hooks:
	git config --local core.hooksPath .githooks
	@echo "hooks active: $$(git config core.hooksPath)"

## Verify native hook setup in fresh clones and a linked worktree.
check-hooks:
	sh ci/hooks.test.sh

clean:
	rm -f *.elc info/heroiclands.info
