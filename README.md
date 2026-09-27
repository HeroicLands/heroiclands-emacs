# heroiclands-emacs

Emacs support for authoring [HeroicLands](https://www.heroiclands.org) content:
working across the repository constellation, previewing a content note in a browser,
querying the content index, and writing wikilinks that are correct
before the build ever sees them.

Everything hangs off the `C-c h` prefix. Press `C-c h` and wait; which-key
lists what is there.

## What it gives you

**Wikilinks with indexed completion.** A wikilink names a note by its Address.
The pinned content language server searches saved names, aliases, shortcodes,
and Addresses across the current project and selected foreign projects.
Typing `[[camel` can offer both Bactrian Camel and Xerathian Bactrian Camel;
matches can occur anywhere in a name or Address. Eglot inserts the shortest
Address that still identifies the selected package, system, and target.

```
[[camel             → Bactrian Camel — sohl-note-being-bctrncml
[[camel             → Xerathian Bactrian Camel — thalorna-sohl-being-bctrncml
[[Killer Whale      → Orca, displayed as Killer Whale
```

Typing `]]` rewrites what you entered into canonical form:

```
[[Aurochs]]                → [[being-aurochs|Aurochs]]
[[Killer Whale]]           → [[being-orca|Killer Whale]]
[[being-aurochs#dossier]]  → [[being-aurochs#dossier|Aurochs]]
```

When Emacs has already inserted the closing `]]` as a pair, accepting a
completion adds the display text immediately and leaves point after the link.

Selecting an exact alias keeps that alias as display text. A selected result
keeps its server supplied target even when another note shares its source file.
When you type a name without choosing a completion, `]]` reports an unknown
or ambiguous name instead of choosing a target for you.

`C-c h .` follows a link, landing on the anchor's line. A package-qualified
link opens the note under its owning project's content tree when that
project's private index is available. `C-c h ,` comes back.

**Wikilinks you can see.** Each part of `[[address#anchor|display]]` is
coloured by what it is — the address strongest, since it has to be exactly
right and nobody can read it; the display half kept close to body text, since
it *is* the prose. A link naming a note the index does not hold, or an anchor
the note does not declare, is drawn broken with a wavy underline, so a dead
link shows while you write it rather than at build time.

A target in a package whose index isn't loaded is never marked broken — not
held is not the same as not there.

**Live note preview.** `C-c h p` opens a separate browser window for the
current note. The page updates three seconds after the last edit, including
unsaved SQL tables, images, links, code fences, and GM disclosures. `C-c h P`
reloads saved project state, configuration, and assets. Pandoc, the pinned
server installation, and the project's installed site theme are required. The
preview never writes to the note or site build directory.

**The content index, queryable.** The pinned language server builds it at
startup and after saves. `C-c h i` refreshes the current project on demand;
`C-c h I` runs a jq filter over it. Each record is a note's own frontmatter.

**Project navigation through Eglot.** Load `heroiclands-eglot` to start the
pinned content language server in content notes. `M-.` follows an
Address or wikilink, `C-M-.` searches the current project's names, aliases,
shortcodes, Addresses, and tags (`tag:myth`). Prefix the query with `all:`
to include the foreign projects selected by `heroiclands-index-projects`;
`all:tag:myth` searches their tags. Results show the owning package.
`M-?` lists authored references across the selected projects, and `M-,`
returns. Search reads the saved private JSONL index.
The existing `C-c h .` and `C-c h ,` commands remain available.

**The constellation.** `C-c h g` ripgreps every repository at once; `C-c h h`
jumps between them; `C-c h c/b/t/l` run the project's npm scripts into a
compile buffer whose diagnostics are clickable.

## Requirements

- Emacs 29.1 or newer
- The project's installed `@heroiclands/hugo-theme` for preview styling
- The pinned content language server installation for preview rendering
- `node`, `jq`, and `pandoc` on `PATH`
- `npm` to install the pinned content language server
- `rg` on `PATH` for `C-c h g` cross-project text search
- `makeinfo` to build the manual

The content features activate in Markdown files whose opening YAML frontmatter
has top-level `type` and `shortcode` values. Eglot also needs a content project
configuration to build its index.

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
(require 'heroiclands-server)     ; pinned server installation and index cache
(require 'heroiclands-index)      ; the content index
(require 'heroiclands-goto)       ; wikilink normalization and following
(require 'heroiclands-highlight)  ; colouring, and marking dead links
(require 'heroiclands-preview)    ; live browser preview
(require 'heroiclands-hbs)        ; Handlebars helper completion
(require 'heroiclands-eglot)      ; indexed completion and Xref through Eglot

;; Where your content repositories live. Either a directory holding them,
;; or the projects themselves, or a mixture — see below.
(setq heroiclands-project-roots '("~/dev/github"))

(global-heroiclands-mode 1)       ; turn it on where it applies
```

Run `M-x heroiclands-server-install` once after installation or an Emacs
package upgrade. It runs `npm ci` against this package's exact lockfile in
`user-emacs-directory/heroiclands/content-language-server/`. The server uses
its own exact `@heroiclands/package-build` dependency, so project builds and
`npm run clean` cannot change the editor's runtime or erase its index.
The selected server version is in `server/package.json`; the installed server
and generator versions are in `server/package-lock.json`.
Customize `heroiclands-server-directory` to change the install location.
`heroiclands-eglot-server-command` accepts an explicit command list for
server development; its default uses the pinned installation.

Each `require` after the first is optional — load only the features you want,
and the mode installs whichever are present.

With `use-package` and a VC recipe (Emacs 29+):

```elisp
(use-package heroiclands
  :vc (:url "https://github.com/HeroicLands/heroiclands-emacs"
       :rev :newest
       :doc "doc/heroiclands.texi")     ; without this there is no manual
  :config
  (require 'heroiclands-index)
  (require 'heroiclands-server)
  (require 'heroiclands-goto)
  (require 'heroiclands-highlight)
  (require 'heroiclands-preview)
  (require 'heroiclands-hbs)
  (require 'heroiclands-eglot)
  (setq heroiclands-project-roots '("~/dev/github"))
  (global-heroiclands-mode 1))
```

**`:doc` is not optional.** `package-vc` builds a manual only from the file the
spec names — it runs `makeinfo` and `install-info` on it — so leaving it out
installs the code without the documentation, and `C-c h ?` and `C-h i` both
come up empty.

Or with `straight.el`, which does not build Texinfo; run `make` in the clone:

```elisp
(straight-use-package
 '(heroiclands :type git :host github :repo "HeroicLands/heroiclands-emacs"))
(setq heroiclands-project-roots '("~/dev/github"))
(global-heroiclands-mode 1)
```

### If you are working *on* this package

Load it from the checkout you edit, not from a second copy a package manager
made:

```elisp
(use-package heroiclands
  :ensure nil          ; it is not on an archive
  :demand t            ; nothing defers to; the mode must be armed at startup
  :load-path "~/dev/github/heroiclands-emacs"
  :config
  (require 'heroiclands-index)
  (require 'heroiclands-server)
  (require 'heroiclands-goto)
  (require 'heroiclands-highlight)
  (require 'heroiclands-preview)
  (require 'heroiclands-hbs)
  (setq heroiclands-project-roots '("~/dev/github"))
  (global-heroiclands-mode 1))
```

A `:vc` recipe would clone into `elpa/` and ignore your working tree, so every
change would need a commit, a push and a `package-vc-upgrade` before Emacs saw
it. Build the manual yourself with `make`; nothing else differs.

`:ensure nil` matters if your config sets `use-package-always-ensure` — there
is no archive package to install — and `:demand t` if it sets
`use-package-always-defer`, since there is nothing to defer *until*:
`global-heroiclands-mode` has to be on before the first content note is
opened, and a deferred `:config` never runs.

### What the frontmatter decides, and what the index decides

Two different things gate this package.

The **frontmatter** identifies a content note, wherever the file is saved.
The **content index** decides which capabilities are *live*:

| Needs the index | Works without it |
| --- | --- |
| Eglot completion after `[[` | Colouring wikilinks by part |
| Rewriting a link on `]]` | Live browser preview |
| `C-c h .` following a link | `C-c h i`, which builds one |
| Marking a link broken | The `C-c h` repository commands |

Each behaves differently without one, deliberately: `C-c h .` refuses and names
the command that builds an index; Eglot completion offers nothing until its
server has an index; `]]`
leaves the link as typed and **says so** once per buffer, because silence there
is the worst outcome — you asked for a check and would get neither the check nor
a reason; and colouring continues without the verdict.

So the mode still turns on without an index — withholding it would take away
the preview and the colouring, which don't need one, and leave no way to see
why. It also **says so**: the lighter reads `HL?` rather than `HL`, and enabling
it in a buffer with no index tells you once where to get one.

`C-c h i` refreshes the current project and re-examines open content buffers.
The server also rebuilds on startup and after saves; Emacs notices published
private indexes and refreshes the lighter and broken-link marking.

### Where it turns itself on

`global-heroiclands-mode` enables `heroiclands-mode` in a buffer that is all
three of:

1. visiting a file (not a scratch buffer),
2. in `markdown-mode` or `gfm-mode`, and
3. starting with YAML frontmatter containing nonempty, top-level `type` and
   `shortcode` values.

For example:

```yaml
---
type: lore
shortcode: movednote
---
```

The check reads the file, not its directory. A README beside content notes stays
ordinary Markdown unless it declares both fields. Eglot starts only when the
note also belongs to a content project carrying one of these configuration
files, which the server uses to build its index:

```
package-build.config.yaml
package-build.config.yml
package-build.config.mjs
```

The server indexes the content path declared by that configuration. A note
outside that path still gets `heroiclands-mode`, while server navigation uses
the configured index.

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
completions, the wikilink machinery, and the live preview for the buffer.
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
| `C-c h i` | Refresh this project's private content index |
| `C-c h I` | Query it with a jq filter |
| `C-c h .` | Follow the wikilink at point, landing on its anchor |
| `C-c h ,` | Jump back |
| `C-c h p` | Toggle the live browser preview |
| `C-c h P` | Reload saved project state and assets in the preview |
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

Save notes to make their metadata available to search. The server refreshes
its index after saves. Use `C-c h i` to refresh the current project when a
result appears stale.

### Finding your projects

`heroiclands-project-roots` is the list of places to look. Each entry is
searched like this:

- if the directory is **itself a project** — a git checkout carrying a
  `package-build.config.*` — it is taken as one, and **not searched further**;
- otherwise its subdirectories are searched, down to
  `heroiclands-project-search-depth` (3).

Searching stops at a project deliberately: a checkout inside a checkout — a
worktree under `.claude/worktrees/`, a vendored source — is the *same* project,
not another one.

`C-c h h` includes a root that is itself a repository and repositories
immediately inside a directory root. So a root may be a directory holding
your repositories:

```elisp
(setq heroiclands-project-roots '("~/dev/github"))
```

or the projects themselves, or any mixture:

```elisp
(setq heroiclands-project-roots
      '("~/work/heroiclands"          ; a directory of repositories
        "~/src/sohl-thalorna"))       ; one specific project
```

**Left unset, it searches nowhere.** Nothing about your filesystem is
guessed — not a conventional directory, not the siblings of the current
checkout — because either would be this package asserting where your
repositories ought to live.

What that costs is bounded, and worth knowing precisely:

| With no roots set | |
| --- | --- |
| The mode | still turns on |
| The local project's index | still loads — `project.el` finds the buffer's own checkout |
| `[[being-aurochs]]` | resolves; a dead local link is still flagged |
| `[[thalorna-being-x]]` | not resolvable, and correctly *not* flagged |
| `C-c h h` | no repositories listed |
| `C-c h g` | searches the current project or directory |

So setting it is what buys you links **across** packages, and the
constellation commands. Local editing works without it.

A linked worktree counts as a checkout (`.git` is a file there rather than a
directory). Someone editing in one should not find the package inert.

`M-x heroiclands-refresh-projects` searches again after you clone or remove a
repository; the result is cached in between, since it walks the filesystem.

### Package names are not directory names

A wikilink names a **package**; a root holds **directories**. In this
constellation the two have never once matched:

| Directory | Publishes |
| --- | --- |
| `Song-of-Heroic-Lands-FoundryVTT` | `sohl` |
| `sohl-thalorna` | `thalorna` |
| `sohl-kethira-basic` | `kethira` |
| `HarnMaster-3-FoundryVTT` | `hm3` |

So `heroiclands-index-projects` matches an entry against the **package name
first**, and the directory name second — write `"thalorna"`, the name you
already know from links, and it finds `sohl-thalorna` wherever it is cloned.
An entry containing a slash is taken as a path.

The package name is read from `contentPackage` in the configuration — the one
thing worth taking from that file rather than from an index, because it is
wanted *before* an index exists, which is exactly when you are saying which
projects to load.

Both configuration forms are read, with a difference that matters. In YAML a
bare word is a string, so quoted and unquoted mean the same. In JavaScript a
bare word is a *variable*, so only a quoted literal is taken from a `.mjs` —
that form exists so values can be computed, and reading an identifier as
though it were the name would be inventing an answer. A computed one yields
nothing, and the project stays selectable by directory or path.

### Links to other packages

A wikilink may name a note in another package by its canonical
`<package>-<system>-<type>-<shortcode>` Address —
`sohl-note-being-aurochs` cited from a
`thalorna` note. Resolving one means holding that package's index too, so
`heroiclands-index-projects` selects the foreign projects for Eglot and
existing indexes for Emacs link following and highlighting. It defaults to
every project that `heroiclands-project-roots` finds. Eglot builds a missing
foreign index when completion, search, definition, or references need it.
Restart Eglot in open content buffers after changing the selection.

A target belonging to a package that **isn't** loaded is never marked broken.
Not held is not the same as not there, and a colour that guesses is a colour
nobody trusts. Only a link whose package *is* loaded, or a bare local slug,
can be reported dead.

## Configuration

| Variable | Default | What it does |
| --- | --- | --- |

| `heroiclands-markers` | the three `package-build.config.*` names | What marks a project |
| `heroiclands-server-directory` | under `user-emacs-directory` | Pinned server installation |
| `heroiclands-eglot-server-command` | `nil` | Explicit server command for development |
| `heroiclands-goto-canonicalize-on-close` | `t` | Rewrite a link when `]]` is typed |
| `heroiclands-project-roots` | `nil` | Where to look for projects; nil = no discovered projects |
| `heroiclands-project-search-depth` | `3` | How far below a root to search |
| `heroiclands-index-projects` | `all` | Foreign projects for Eglot and local link resolution |
| `heroiclands-highlight-check-targets` | `t` | Mark links the index says are dead |
| `heroiclands-preview-idle-delay` | `3` | Idle seconds before rendering |
| `heroiclands-preview-new-window` | `t` | Request a separate browser window |
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
| `heroiclands.el` | The constellation: projects, ripgrep, compile, and the `C-c h` map |
| `heroiclands-server.el` | Pinned server installation and private index validation |
| `heroiclands-index.el` | Refreshing and querying the content index |
| `heroiclands-goto.el` | Wikilink normalization and following |
| `heroiclands-eglot.el` | Indexed completion and Xref through the pinned server |
| `heroiclands-preview.el` | Live browser preview |
| `heroiclands-preview.mjs` | Single-page renderer and loopback browser page |
| `heroiclands-hbs.el` | Handlebars helper completion in `.hbs` templates |
| `doc/heroiclands.texi` | The manual |

## Licence

[GPL-3.0-or-later](LICENSE). In plain terms:

**You may use it for anything, commercial or not.** Charge for what you make
with it. Use it at work. Nobody needs permission, and no fee is owed. The GPL
has never restricted commercial use — that is the most common misreading of it.

**You may use it on closed projects.** Author a paid FoundryVTT module — for
Kethira, or any other setting, free or not — with this package as your editor
tooling. Your module is yours and stays closed if you want it closed. Using a
tool to write something has never made the something a derivative of the tool;
GCC compiles proprietary code, and Emacs edits proprietary files, for the same
reason.

**But this package, and everything derived from it, stays free.** Modify it,
extend it, fork it — and if you distribute what you made, it carries the same
licence, with source. An improvement to the package cannot be taken private.

That is the whole trade: **use it however you like, including to make money on
closed work; but the package itself, and every version of it, belongs to
everyone.**

### The fine print worth knowing

- The obligation triggers on **distribution**, not on modification. A private
  copy may be hacked and never shared. Only the AGPL closes that gap, and it
  would reach into the closed work above, which is not the intent.
- The only thing this licence forbids that a permissive one would allow is
  shipping these files **inside** a closed product. That is deliberate: it is
  the case where an improvement would otherwise disappear.
- GPL-3 is what Emacs itself and the rest of the HeroicLands repositories use,
  so code moves between them without a licensing question.
