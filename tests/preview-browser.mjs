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

async function start(t, install, root) {
    const child = spawn(process.execPath, [script, install, root, path.join(root, "note.md")],
        { cwd: root, stdio: ["pipe", "pipe", "pipe"] });
    // A startup diagnostic can arrive just before the helper exits; cleanup may
    // race that exit. Other unexpected exits are reported by next().
    child.stdin.on("error", error => { if (error.code !== "EPIPE") throw error; });
    const lines = readline.createInterface({ input: child.stdout });
    const events = [];
    let stderr = "";
    child.stderr.on("data", chunk => { stderr += chunk; });
    lines.on("line", line => events.push(JSON.parse(line)));
    const exited = new Promise(resolve => child.once("exit", resolve));
    t.after(async () => {
        if (child.exitCode === null) {
            child.stdin.end('{"type":"stop"}\n');
            await exited;
        }
    });
    const next = async () => {
        const deadline = Date.now() + 15000;
        while (!events.length) {
            if (child.exitCode !== null) throw new Error(`preview exited: ${stderr}`);
            if (Date.now() > deadline) throw new Error(`preview event timed out: ${stderr}`);
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        return events.shift();
    };
    return { next, send: message => child.stdin.write(JSON.stringify(message) + "\n") };
}

function fixture(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "hl-preview-browser-"));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    return root;
}

function installFixture(root, source) {
    const install = path.join(root, "install");
    const packageRoot = path.join(install, "node_modules/@heroiclands/package-build");
    fs.mkdirSync(packageRoot, { recursive: true });
    fs.writeFileSync(path.join(install, "package.json"), "{}\n");
    fs.writeFileSync(path.join(packageRoot, "package.json"), JSON.stringify({
        name: "@heroiclands/package-build", type: "module", exports: { "./preview": "./preview.mjs" },
    }));
    fs.writeFileSync(path.join(packageRoot, "preview.mjs"), source);
    return install;
}

test("browser helper uses shared HTML/CSS, preserves good output and discards stale renders", async t => {
    const root = fixture(t);
    const install = installFixture(root, `
export function previewStyles() { return '.hl-preview { color: #24292f }'; }
export async function readPreviewCurrentDate() { return '720.1'; }
export async function renderPreview(text, options) {
  if (text === 'invalid') return {ok:false,findings:[{file:options.file,line:2,message:'invalid fixture'}]};
  if (text === 'slow') await new Promise(resolve => setTimeout(resolve, 150));
  return {ok:true,html:JSON.stringify({text, ...options}),frontmatter:{},findings:[]};
}
`);
    const browser = await start(t, install, root);
    const ready = await browser.next();
    assert.equal(ready.type, "ready");
    const state = async () => (await fetch(`${ready.url}state`)).json();
    browser.send({ type: "render", generation: 1, text: "initial" });
    assert.equal((await browser.next()).type, "rendered");
    const initial = await state();
    assert.deepEqual(JSON.parse(initial.body), {
        text: "initial", dark: false, infobox: true, file: path.join(root, "note.md"), currentDate: "720.1",
    });
    const page = await (await fetch(ready.url)).text();
    assert.match(page, /link.removeAttribute\('href'\)/);
    assert.match(page, /heading.removeAttribute\('id'\)/);
    assert.match(page, /scrollY \/ \(document.documentElement.scrollHeight - innerHeight\)/);
    assert.match(page, /event.preventDefault\(\)/);
    assert.match(await (await fetch(`${ready.url}style.css`)).text(), /\.hl-preview/);
    browser.send({ type: "render", generation: 2, text: "invalid" });
    assert.equal((await browser.next()).type, "error");
    const failed = await state();
    assert.equal(failed.body, initial.body);
    assert.equal(failed.version, initial.version);
    assert.match(failed.error, /note\.md:2: invalid fixture/);
    browser.send({ type: "render", generation: 3, text: "slow" });
    browser.send({ type: "invalidate", generation: 4 });
    browser.send({ type: "render", generation: 4, text: "latest", dark: true, infobox: false });
    assert.deepEqual(await browser.next(), { type: "rendered", generation: 4 });
    const latest = await state();
    assert.equal(latest.dark, true);
    assert.equal(latest.error, "");
    assert.deepEqual(JSON.parse(latest.body), {
        text: "latest", dark: true, infobox: false, file: path.join(root, "note.md"), currentDate: "720.1",
    });
});

test("missing shared export reports an actionable upgrade error", async t => {
    const root = fixture(t);
    fs.writeFileSync(path.join(root, "package.json"), "{}\n");
    const browser = await start(t, root, root);
    const error = await browser.next();
    assert.equal(error.type, "error");
    assert.match(error.message, /requires package-build with the preview export/);
    assert.match(error.message, /Update the pinned server installation/);
});

test("real shared renderer starts and updates without a content tree, config, theme, or index", {
    skip: process.env.PREVIEW_PACKAGE_ROOT ? false : "Set PREVIEW_PACKAGE_ROOT to a package-build checkout or installed server directory with the preview export",
}, async t => {
    const root = fixture(t);
    // The project deliberately contains no note on disk and no dependencies.
    const browser = await start(t, path.resolve(process.env.PREVIEW_PACKAGE_ROOT), root);
    const ready = await browser.next();
    assert.equal(ready.type, "ready");
    const source = `---\nname: Local note\nshortcode: local\ntype: being\nage: 17\n---\n# Unsaved heading\n\n[[missing/address|A label]]{.name}\n\n> [!NOTE]\n> Local alert\n\n\`\`\`sql\nselect * from missing\n\`\`\`\n\n| Name | Value |\n| --- | --- |\n| A | 1 |\n`;
    browser.send({ type: "render", generation: 1, text: source });
    assert.equal((await browser.next()).type, "rendered");
    const first = await (await fetch(`${ready.url}state`)).json();
    assert.match(first.body, /hl-preview-light/);
    assert.match(first.body, /Unsaved heading/);
    assert.match(first.body, /missing\/address/);
    assert.match(first.body, /Local alert/);
    assert.match(first.body, /<table/);
    assert.match(first.body, /select \* from missing/);
    browser.send({ type: "render", generation: 2, text: "# Revised\n\n[[elsewhere|Changed]]", dark: true, infobox: false });
    assert.equal((await browser.next()).type, "rendered");
    const updated = await (await fetch(`${ready.url}state`)).json();
    assert.match(updated.body, /hl-preview-dark/);
    assert.match(updated.body, /Revised/);
    assert.doesNotMatch(updated.body, /Unsaved heading/);
    const css = await (await fetch(`${ready.url}style.css`)).text();
    for (const color of ["#6c3fd1", "#c4b0ff", "#f6faff", "#101a28"]) assert.ok(css.includes(color), color);
    assert.deepEqual(fs.readdirSync(root), []);
    const ageSource = "---\ntype: being\ndata:\n  born: '700.1'\n---\nAge probe: {{ data.age }}\n";
    browser.send({ type: "render", generation: 3, text: ageSource });
    assert.equal((await browser.next()).type, "rendered");
    const defaultDate = await (await fetch(`${ready.url}state`)).json();
    assert.match(defaultDate.body, /Age probe: 20/);
    const config = path.join(root, "package-build.config.yaml");
    fs.writeFileSync(config, 'contentPackage: fixture\ncurrentDate: "740.1"\n');
    browser.send({ type: "render", generation: 4, text: ageSource });
    assert.equal((await browser.next()).type, "rendered");
    const configuredDate = await (await fetch(`${ready.url}state`)).json();
    assert.match(configuredDate.body, /Age probe: 40/);
    fs.writeFileSync(config, 'contentPackage: fixture\ncurrentDate: "741.1"\n');
    browser.send({ type: "render", generation: 5, text: ageSource });
    assert.equal((await browser.next()).type, "rendered");
    const refreshedDate = await (await fetch(`${ready.url}state`)).json();
    assert.match(refreshedDate.body, /Age probe: 41/);
    fs.writeFileSync(config, 'currentDate: "invalid-date"\n');
    browser.send({ type: "render", generation: 6, text: ageSource });
    assert.equal((await browser.next()).type, "error");
    const invalidDate = await (await fetch(`${ready.url}state`)).json();
    assert.equal(invalidDate.body, refreshedDate.body);
    assert.match(invalidDate.error, /currentDate|neutral date/);
    assert.match(invalidDate.error, /package-build\.config\.yaml/);
    fs.writeFileSync(config, 'currentDate: "741.1"\n');
    browser.send({ type: "render", generation: 7,
        text: "---\ntype: being\ndata:\n  born: '700.1'\n  age: 0\n---\nAge probe: {{ data.age }}\n" });
    assert.equal((await browser.next()).type, "rendered");
    const authoredAge = await (await fetch(`${ready.url}state`)).json();
    assert.match(authoredAge.body, /Age probe: 0/);
    browser.send({ type: "render", generation: 8,
        text: "---\ntype: being\ndata:\n  born: unknown\n---\nUnknown birthday\n" });
    assert.equal((await browser.next()).type, "rendered");
    const unknownAge = await (await fetch(`${ready.url}state`)).json();
    assert.doesNotMatch(unknownAge.body, /Not Calculated|<dt>age<\/dt>/);
    assert.deepEqual(fs.readdirSync(root), ["package-build.config.yaml"]);
});
