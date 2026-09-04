# heroiclands-emacs

Emacs support for authoring [HeroicLands](https://www.heroiclands.org) content:
working across the repository constellation, previewing the tables a note
declares, querying the content index, and writing wikilinks that are correct
before the build ever sees them.

Everything hangs off the `C-c h` prefix. Press `C-c h` and wait; which-key
lists what is there.

## What it gives you

**Wikilinks that cannot be wrong.** A wikilink names a note by its address —
`being-aurochs` — which is the half that has to be exact and the half nobody
remembers. Typing `[[` completes on the *name* instead:

```
[[Bactri            → being-bctrncml — Bactrian Camel
[[kurbul            → armorgear-k34hlm — Kûrbúl ¾-Helm (Kurbul 3/4-Helm)
[[Killer            → Killer Whale — being-orca  [being -> Orca]
```

Typing `]]` rewrites what you entered into canonical form:

```
[[Aurochs]]                → [[being-aurochs|Aurochs]]
[[Killer Whale]]           → [[being-orca|Killer Whale]]
[[being-aurochs#dossier]]  → [[being-aurochs#dossier|Aurochs]]
```

An alias keeps *your* wording rather than being replaced by the canonical name.
Anything that is not exactly one note is an error raised where you typed it —
unknown note, ambiguous name, or an anchor the note does not declare — rather
than a broken link that surfaces in a build days later.

`C-c h .` follows a link, landing on the anchor's line. `C-c h ,` comes back.

**Content tables, rendered live.** `C-c h d` previews each fenced `dataview`
block as an overlay beneath it, rendered through the *build's own expander* — so
a preview cannot disagree with what ships. The buffer is never modified.

**The content index, queryable.** `C-c h i` rebuilds it; `C-c h I` runs a jq
filter over it. Each record is a note's own frontmatter, so a query reads
exactly what the note writes.

**The constellation.** `C-c h g` ripgreps every repository at once; `C-c h h`
jumps between them; `C-c h c/b/t/l` run the project's npm scripts into a
compile buffer whose diagnostics are clickable.

## Requirements

- Emacs 29.1 or newer
- [`@heroiclands/package-build`](https://github.com/HeroicLands/package-build)
  in the project, for `content-build content-index` and the table expander
- `node` and `jq` on `PATH`
- `makeinfo` to build the manual

The content features activate in a markdown buffer inside a project carrying
`package-build.config.yaml`; everything else is inert elsewhere.

## Install

Clone it and build the manual:

```bash
git clone https://github.com/HeroicLands/heroiclands-emacs.git \
  ~/dev/github/heroiclands-emacs
make -C ~/dev/github/heroiclands-emacs
```

## Activating it

Add this to your init file. The `require` lines load the package; the last
line is what actually turns the mode on:

```elisp
(add-to-list 'load-path "~/dev/github/heroiclands-emacs")

(require 'heroiclands)            ; the constellation, and the C-c h map
(require 'heroiclands-index)      ; the content index
(require 'heroiclands-goto)       ; wikilink completion and normalization
(require 'heroiclands-dataview)   ; content-table previews
(require 'heroiclands-hbs)        ; Handlebars helper completion

(global-heroiclands-mode 1)       ; turn it on where it applies
```

Each `require` after the first is optional — load only the features you want,
and the mode installs whichever are present.

With `use-package` and a VC recipe (Emacs 30+):

```elisp
(use-package heroiclands
  :vc (:url "https://github.com/HeroicLands/heroiclands-emacs" :rev :newest)
  :config
  (require 'heroiclands-index)
  (require 'heroiclands-goto)
  (require 'heroiclands-dataview)
  (global-heroiclands-mode 1))
```

Or with `straight.el`:

```elisp
(straight-use-package
 '(heroiclands :type git :host github :repo "HeroicLands/heroiclands-emacs"))
(global-heroiclands-mode 1)
```

### Where it turns itself on

`global-heroiclands-mode` enables `heroiclands-mode` in a buffer that is all
three of:

1. visiting a file (not a scratch buffer),
2. in `markdown-mode` or `gfm-mode`, and
3. inside a directory tree containing a **package-build configuration**.

That third test walks up from the file looking for any of the three names
package-build itself resolves — `heroiclands-markers`:

```
package-build.config.yaml
package-build.config.yml
package-build.config.mjs
```

Any one is enough. (`.mjs` is package-build's escape hatch for a consumer that
computes its configuration rather than declaring it. Two of them in one
directory is an error, but that is package-build's error to report — this
package just needs to recognise a project.)

So a note in a new repository is covered the day the repository exists, and
nothing needs marking.

The `HL` lighter in the mode line says when it is on; `C-h m` describes it.

### Turning it on somewhere else

**A whole tree — the cleanest option.** A `.dir-locals.el` in the directory:

```elisp
((markdown-mode . ((mode . heroiclands))))
```

Every markdown buffer at or below it gets the mode, whether or not a
package-build configuration is anywhere above.

**One file.** A Local Variables block at the end:

```markdown
<!-- Local Variables: -->
<!-- eval: (heroiclands-mode 1) -->
<!-- End: -->
```

Emacs looks for this in the last part of the file, and each line must sit
inside a comment — hence the `<!-- -->` wrappers. The package registers this
form in `safe-local-eval-forms`, so Emacs applies it without asking.

**Just this once.** `M-x heroiclands-mode`.

Turning it off — by that command, or by removing the marking — removes the
completions, the wikilink machinery, and any table previews from the buffer.
That is the point of it being a mode.

#### Two forms that look right and are not

**Do not use the first-line `-*-` form in a content note.**

```markdown
<!-- -*- mode: markdown; mode: heroiclands; -*- -->   ← breaks the note
```

A content note's frontmatter must open the file: the `---` has to be on line
one. A comment above it displaces the delimiter, and both gray-matter and
package-build's own parser then read the note as having **no frontmatter** —
so the build skips it silently. The editor convenience would cost you the
note.

**Do not use `mode:` in the end-of-file block.**

```markdown
<!-- Local Variables: -->
<!-- mode: heroiclands -->        ← leaves you in fundamental-mode
<!-- End: -->
```

A `mode:` entry there is taken as the *major* mode. Emacs enables the minor
mode, then leaves the buffer in `fundamental-mode` — no markdown syntax
highlighting, and nothing says why. Adding `mode: markdown` before it does not
help. Use `eval:` instead; `.dir-locals.el` is unaffected, because its `mode`
entry is applied after the major mode is already set.

### What is *not* in the mode

The `C-c h` prefix stays global on purpose. Jumping between repositories and
grepping across all of them are things you do from anywhere, including from a
buffer belonging to no project at all.

## Usage

Once the mode is on, everything is reachable two ways: a key, or a question
you ask Emacs.

### The keys

| Key | Does |
| --- | --- |
| `C-c h ?` | **Open the manual** |
| `C-c h i` | Rebuild this project's content index |
| `C-c h I` | Query it with a jq filter |
| `C-c h .` | Follow the wikilink at point, landing on its anchor |
| `C-c h ,` | Jump back |
| `C-c h d` | Toggle content-table previews |
| `C-c h D` | Re-render them |
| `C-c h h` | Jump to any repository |
| `C-c h g` | Ripgrep across every repository at once |
| `C-c h f` | Find a content note by filename |
| `C-c h m` | Find a content note by canonical key |
| `C-c h c` / `b` / `t` / `l` | Compile · typecheck · test · lint |
| `C-c h H` / `R` | Describe a Handlebars helper · rescan them |

Press `C-c h` and wait; which-key lists the rest.

And while typing in a note: `[[` starts a wikilink and opens completion; `]]`
closes it and rewrites it into canonical form, or says why it cannot.

### Asking Emacs

The manual is a real Info manual, so it lives where Emacs documentation lives
and every standard help key reaches it:

| Ask | Get |
| --- | --- |
| `C-c h ?` | The manual, at the top |
| `C-h i` | The Info directory — it is listed under **Emacs**, beside the Emacs manual and every other |
| `C-h f` *command* | That command's own documentation, with a link into the relevant manual node |
| `C-h m` | In a content note: what `heroiclands-mode` does |
| `C-h v heroiclands-markers` | Any configuration variable, with its docstring |
| `C-h k` *key* | What a key is bound to |

Nothing here needs a browser or a copy of this README.

### The one habit worth keeping

Rebuild the index (`C-c h i`) after adding or renaming notes. Completion, link
following, and normalization all read the index rather than the tree, and
nothing rebuilds it for you.

## Configuration

| Variable | Default | What it does |
| --- | --- | --- |
| `heroiclands-root` | `~/dev/github` | Where the repositories live |
| `heroiclands-markers` | the three `package-build.config.*` names | What marks a project |
| `heroiclands-index-relative-dir` | `build/content-index` | Where the index is written |
| `heroiclands-goto-canonicalize-on-close` | `t` | Rewrite a link when `]]` is typed |
| `heroiclands-dataview-max-rows` | `40` | Preview truncation; `nil` for all |
| `heroiclands-index-jq` | `jq` | The jq executable |

## Documentation

The manual source is `doc/heroiclands.texi`, written in
[Texinfo](https://www.gnu.org/software/texinfo/) and compiled by `makeinfo`:

```bash
make info      # makeinfo --no-split -o info/heroiclands.info doc/heroiclands.texi
```

`make` alone does the same. The built `info/heroiclands.info` is **not
committed** — it is generated, so clone-then-`make` is the install.

If `makeinfo` is missing, install GNU Texinfo (`brew install texinfo`,
`apt install texinfo`). Its own manual is the reference for the source format:

- [Texinfo manual](https://www.gnu.org/software/texinfo/manual/texinfo/) — the
  markup used in `doc/heroiclands.texi`
- [`makeinfo` invocation](https://www.gnu.org/software/texinfo/manual/texinfo/html_node/Invoking-texi2any.html)
  — the command's own options
- `info texinfo` locally, once Texinfo is installed

The package registers its own `info/` directory with `Info-directory-list`, so
the manual appears in `C-h i` without an `install-info` step or any change to
`INFOPATH`.

When adding a command, end its docstring with ``See Info node
`(heroiclands)Some Node'.`` — help-mode turns that into a live button, which is
what keeps `C-h f` and the manual joined up.

## Layout

| File | What it does |
| --- | --- |
| `heroiclands.el` | The constellation: projects, ripgrep, compile, link-manifest completion, and the `C-c h` map |
| `heroiclands-index.el` | Rebuilding and querying the content index |
| `heroiclands-goto.el` | Wikilink completion, normalization, and following |
| `heroiclands-dataview.el` | Content-table previews |
| `heroiclands-dataview.mjs` | Renders a note's queries through the build's expander |
| `heroiclands-hbs.el` | Handlebars helper completion in `.hbs` templates |
| `doc/heroiclands.texi` | The manual |

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).
