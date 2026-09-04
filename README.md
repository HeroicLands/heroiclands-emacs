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

Clone it, build the manual, and load it:

```bash
git clone https://github.com/HeroicLands/heroiclands-emacs.git \
  ~/dev/github/heroiclands-emacs
make -C ~/dev/github/heroiclands-emacs
```

```elisp
(add-to-list 'load-path "~/dev/github/heroiclands-emacs")
(require 'heroiclands)
(require 'heroiclands-hbs)
(require 'heroiclands-dataview)
(require 'heroiclands-index)
(require 'heroiclands-goto)

(global-heroiclands-mode 1)
```

## The mode

The buffer-local half is a minor mode, `heroiclands-mode` — the wikilink
machinery and the completions, everything genuinely about *this* buffer.
`C-h m` describes it; the `HL` lighter says when it is on.

`global-heroiclands-mode` turns it on in any markdown buffer inside a project
carrying `package-build.config.yaml`, so normally there is nothing to mark. To
enable it somewhere that rule would not catch:

```markdown
<!-- -*- mode: markdown; mode: heroiclands; -*- -->
```

or for a whole tree, a `.dir-locals.el`:

```elisp
((markdown-mode . ((mode . heroiclands))))
```

or just `M-x heroiclands-mode`. Turning it off removes the completions, the
wikilink machinery, and any table previews from that buffer.

The `C-c h` prefix is deliberately **not** part of the mode and stays global:
jumping between repositories is something you do from anywhere.

With `use-package` and a straight/elpaca-style recipe, point it at this
repository and require the same five features.

## Documentation

`C-c h ?` opens the manual, which is also listed in `C-h i` under Emacs
alongside every other Emacs manual. Every command documents itself in `C-h f`
and links back into the relevant manual node.

`make` builds `info/heroiclands.info` from `doc/heroiclands.texi`; the built
file is not committed.

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
