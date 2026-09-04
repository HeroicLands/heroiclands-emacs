# heroiclands-emacs

EMACS ?= emacs
MAKEINFO ?= makeinfo

LISP := heroiclands.el heroiclands-hbs.el heroiclands-dataview.el \
        heroiclands-index.el heroiclands-goto.el

.PHONY: all info compile check hooks clean

all: info

## Build the Info manual, which `C-c h ?' and `C-h i' both read.
info: info/heroiclands.info

info/heroiclands.info: doc/heroiclands.texi
	@mkdir -p info
	$(MAKEINFO) --no-split -o $@ $<

## Byte-compile, with warnings shown. Not required to use the package.
compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile $(LISP)

## Load every file in a clean Emacs, which catches a broken require or defun.
##
## The eval form is kept on ONE line deliberately: a `\'-continuation inside a
## quoted argument is passed through to Emacs by some makes, which then reads a
## bare backslash as a variable and fails with `void-variable \'.
check:
	$(EMACS) -Q --batch -L . --eval '(mapc (lambda (f) (require (intern f))) (list "heroiclands" "heroiclands-hbs" "heroiclands-dataview" "heroiclands-index" "heroiclands-goto"))' --eval '(message "all features load")'

## Activate the committed git hooks for this checkout.
##
## sohl-thalorna does this from npm's `prepare' script; there is no package
## manifest here, so it is a target you run once after cloning. The hooks
## refuse a commit carrying AI attribution, and refuse committing on `main' --
## the same rules the No Attribution workflow and the branch ruleset enforce
## server-side, moved forward to where the fix is still cheap.
hooks:
	git config core.hooksPath .githooks
	@echo "hooks active: $$(git config core.hooksPath)"

clean:
	rm -f *.elc info/heroiclands.info
