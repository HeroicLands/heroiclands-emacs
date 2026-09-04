#!/usr/bin/env node
/**
 * Render the `dataview` TABLE queries in one content note, using the *same*
 * expander the content build uses (`@heroiclands/package-build`), so an Emacs
 * preview cannot drift from what ships.
 *
 * Usage:  node heroiclands-dataview.mjs <note-path> [--stdin]
 *
 * With `--stdin` the note body is read from standard input instead of disk, so
 * an unsaved buffer previews what it currently holds.
 *
 * Prints one JSON object on stdout:
 *   { root, contentRoot, notes, blocks: [ { index, table, error } ] }
 * `index` is the 0-based ordinal of the fenced `dataview` block in the note.
 */
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const MARKER = "package-build.config.yaml";

/** Walk up from `start` to the directory holding the config marker. */
function findRoot(start) {
    let dir = fs.statSync(start).isDirectory() ? start : path.dirname(start);
    for (;;) {
        if (fs.existsSync(path.join(dir, MARKER))) return dir;
        const up = path.dirname(dir);
        if (up === dir) throw new Error(`no ${MARKER} above ${start}`);
        dir = up;
    }
}

/**
 * Import a module out of the project's `node_modules`, searching upward from
 * `root`. A git worktree has no `node_modules` of its own, so a note edited in
 * one resolves against the checkout the worktree belongs to.
 */
function fromRoot(root, spec) {
    for (let dir = root; ; dir = path.dirname(dir)) {
        const file = path.join(dir, "node_modules", spec);
        if (fs.existsSync(file)) return import(pathToFileURL(file).href);
        if (path.dirname(dir) === dir) break;
    }
    throw new Error(`cannot resolve ${spec} from ${root} or any parent`);
}

/** Every `.md` below `dir`, recursively. */
function walk(dir, out = []) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        if (e.name.startsWith(".")) continue;
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out);
        else if (e.name.endsWith(".md")) out.push(p);
    }
    return out;
}

/** Read `contentPackage:` and `paths.content:` without a YAML dependency. */
function readConfig(root) {
    const text = fs.readFileSync(path.join(root, MARKER), "utf8");
    const pkg = /^contentPackage:\s*(\S+)/m.exec(text)?.[1] ?? null;
    let content = "assets/content";
    const paths = /^paths:\s*$([\s\S]*?)^\S/m.exec(text + "\nX");
    if (paths) {
        const m = /^\s+content:\s*(\S+)/m.exec(paths[1]);
        if (m) content = m[1].replace(/^["']|["']$/g, "");
    }
    return { contentPackage: pkg, content };
}

/** The fenced `dataview` blocks in a markdown body, in order. */
function queryBlocks(markdown) {
    const lines = String(markdown ?? "").split("\n");
    const blocks = [];
    for (let i = 0; i < lines.length; i++) {
        const open = /^([ \t]*)(`{3,}|~{3,})[ \t]*(.*)$/.exec(lines[i]);
        if (!open) continue;
        const [, , marker, info] = open;
        const closer = new RegExp(`^[ \\t]*${marker[0]}{${marker.length},}[ \\t]*$`);
        let close = i + 1;
        while (close < lines.length && !closer.test(lines[close])) close++;
        if (close < lines.length && /^dataview\b/i.test(info.trim()))
            blocks.push({ query: lines.slice(i + 1, close).join("\n") });
        i = close;
    }
    return blocks;
}

async function main() {
    const args = process.argv.slice(2);
    const useStdin = args.includes("--stdin");
    const notePath = path.resolve(args.find((a) => !a.startsWith("--")) ?? ".");
    const root = findRoot(notePath);
    const { contentPackage, content } = readConfig(root);
    const contentRoot = path.join(root, content);

    const [tables, matterMod] = await Promise.all([
        fromRoot(root, "@heroiclands/package-build/engine/content-tables.mjs"),
        fromRoot(root, "gray-matter/index.js"),
    ]);
    const matter = matterMod.default ?? matterMod;

    const body = useStdin ?
        fs.readFileSync(0, "utf8")
    :   fs.readFileSync(notePath, "utf8");

    /** Every note in the tree, as the expander's `{ fm, path }` doc. */
    const docs = [];
    let self;
    for (const file of walk(contentRoot)) {
        let fm;
        try {
            fm = matter.read(file).data ?? {};
        } catch {
            continue;
        }
        const rel = path.relative(contentRoot, file);
        const doc = { fm: { ...fm, package: contentPackage }, path: rel };
        docs.push(doc);
        if (file === notePath) self = doc;
    }
    if (!self) {
        // The note is outside the content tree (or unsaved elsewhere) — `this`
        // still has to resolve, so build it from the body we were handed.
        const fm = matter(body).data ?? {};
        self = {
            fm: { ...fm, package: contentPackage },
            path: path.relative(contentRoot, notePath),
        };
    }

    // A note is linkable exactly when the build could address it.
    const linkable = (d) => Boolean(d?.fm?.type && d?.fm?.shortcode);

    const blocks = queryBlocks(matter(body).content ?? body).map((b, index) => {
        try {
            const spec = tables.parseDataviewQuery(b.query);
            const rows = tables.selectRows(spec, docs, self);
            return {
                index,
                table: tables.renderContentTable(spec, rows, linkable, self),
                rows: rows.length,
                error: null,
            };
        } catch (e) {
            return { index, table: null, rows: 0, error: e.message };
        }
    });

    process.stdout.write(
        JSON.stringify({ root, contentRoot, notes: docs.length, blocks }),
    );
}

main().catch((e) => {
    process.stdout.write(JSON.stringify({ fatal: e.message }));
    process.exit(1);
});
