/* SPDX-License-Identifier: GPL-3.0-or-later */

import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import readline from "node:readline";

const directory = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(directory, "../heroiclands-preview.mjs");

test("browser page renders representative content and keeps the last good page", async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "hl-preview-browser-"));
    const install = path.join(root, "install");
    const packageRoot = path.join(install, "node_modules/@heroiclands/package-build");
    const theme = path.join(root, "node_modules/@heroiclands/hugo-theme/static/css");
    const note = path.join(root, "note.md");
    fs.mkdirSync(path.join(packageRoot, "engine"), { recursive: true });
    fs.mkdirSync(theme, { recursive: true });
    fs.writeFileSync(path.join(install, "package.json"), "{}\n");
    fs.writeFileSync(path.join(packageRoot, "package.json"),
        JSON.stringify({ name: "@heroiclands/package-build", type: "module", exports: { "./package.json": "./package.json" } }));
    const generatedBoxes = [{ id: "profile", kind: "note", title: "Profile", sections: [
        { layout: "rows", label: "Facts", rows: [
            { label: "Population", kind: "number", value: 1500 },
            { label: "Patron", kind: "link", value: { text: "A & B", url: "/patron/" } },
        ] },
    ] }];
    fs.writeFileSync(path.join(packageRoot, "engine/index.mjs"), `
export const sitePreview = { async prepareSitePreview() {
  return { async render(_file, text) {
    if (text.includes('invalid query')) return {ok:false,findings:[{file:'note.md',line:2,message:'invalid query'}]};
    const boxes = ${JSON.stringify(generatedBoxes)};
    if (text.includes('Revised')) boxes[0].title = 'Revised Profile';
    return {ok:true,markdown:text,frontmatter:{infoboxes:boxes},findings:[]};
  }, async refresh() {}, async close() {} };
} };\n`);
    fs.writeFileSync(path.join(theme, "style.css"),
        "body { color: #123456; } .single-with-sidebar { display: grid; } " +
        "@media(max-width:960px) { .single-with-sidebar { grid-template-columns: 1fr; } }\n");
    fs.writeFileSync(note, "fixture\n");
    const child = spawn("node", [script, install, root, note],
        { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
    const lines = readline.createInterface({ input: child.stdout });
    const events = [];
    lines.on("line", line => events.push(JSON.parse(line)));
    const next = () => new Promise((resolve, reject) => {
        const deadline = setTimeout(() => reject(new Error("preview event timed out")), 15000);
        const poll = () => {
            if (events.length) { clearTimeout(deadline); resolve(events.shift()); }
            else setTimeout(poll, 10);
        };
        poll();
    });
    try {
        const ready = await next();
        assert.equal(ready.type, "ready");
        const markdown = "# A heading\n\n[Place](/somewhere/)\n\n| Name | Value |\n| --- | --- |\n| A | 1 |\n\n![Map](https://example.org/map.webp)\n\n```js\nconst x = 1;\n```\n\n<details><summary>Spoiler</summary>GM clue</details>\n";
        child.stdin.write(JSON.stringify({ type: "render", generation: 1, text: markdown }) + "\n");
        assert.equal((await next()).type, "rendered");
        const state = await (await fetch(`${ready.url}state`)).json();
        assert.match(state.body, /<table>/);
        assert.match(state.body, /<img /);
        assert.match(state.body, /<pre\b/);
        assert.match(state.body, /<details>/);
        assert.match(state.body, /Place/);
        assert.match(state.infobox, /class="info-sidebar info-box info-box-profile"/);
        assert.match(state.infobox, /Population<\/dt><dd>1,500/);
        assert.match(state.infobox, /A &amp; B/);
        const page = await (await fetch(ready.url)).text();
        assert.match(page, /link.removeAttribute\('href'\)/);
        assert.match(page, /heading.removeAttribute\('id'\)/);
        assert.match(page, /classList.toggle\('single-with-sidebar'/);
        const style = await (await fetch(`${ready.url}style.css`)).text();
        assert.match(style, /#123456/);
        assert.match(style, /@media\(max-width:960px\)/);
        child.stdin.write(JSON.stringify({ type: "render", generation: 2, text: "invalid query" }) + "\n");
        assert.equal((await next()).type, "error");
        const failed = await (await fetch(`${ready.url}state`)).json();
        assert.equal(failed.body, state.body);
        assert.equal(failed.infobox, state.infobox);
        assert.match(failed.error, /invalid query/);
        child.stdin.write(JSON.stringify({ type: "render", generation: 3, text: markdown,
            infobox: false }) + "\n");
        assert.equal((await next()).type, "rendered");
        const bodyOnly = await (await fetch(`${ready.url}state`)).json();
        assert.equal(bodyOnly.infobox, "");
        child.stdin.write(JSON.stringify({ type: "render", generation: 4,
            text: "Revised", infobox: true }) + "\n");
        assert.equal((await next()).type, "rendered");
        const revised = await (await fetch(`${ready.url}state`)).json();
        assert.match(revised.infobox, /Revised Profile/);
    } finally {
        child.stdin.write('{"type":"stop"}\n');
        child.stdin.end();
        await new Promise(resolve => child.once("exit", resolve));
        fs.rmSync(root, { recursive: true, force: true });
    }
});
