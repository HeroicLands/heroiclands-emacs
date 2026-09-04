# heroiclands-emacs

EMACS ?= emacs
MAKEINFO ?= makeinfo

LISP := heroiclands.el heroiclands-hbs.el heroiclands-dataview.el \
        heroiclands-index.el heroiclands-goto.el

.PHONY: all info compile check clean

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
check:
	$(EMACS) -Q --batch -L . \
	  --eval '(dolist (f (list "heroiclands" "heroiclands-hbs" \
	                           "heroiclands-dataview" "heroiclands-index" \
	                           "heroiclands-goto")) (require (intern f)))' \
	  --eval '(message "all features load")'

clean:
	rm -f *.elc info/heroiclands.info
