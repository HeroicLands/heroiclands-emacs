/* SPDX-License-Identifier: GPL-3.0-or-later */

import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import readline from "node:readline";
import { renderInfoboxes } from "./heroiclands-preview-infobox.mjs";

const install = process.argv[2];
const root = process.argv[3];
const file = process.argv[4];
const port = process.argv[5] ? Number(process.argv[5]) : 0;
if (!install || !root || !file) {
    process.stderr.write("usage: heroiclands-preview.mjs INSTALL ROOT FILE\n");
    process.exit(2);
}
process.chdir(root);
const installedRequire = createRequire(path.join(install, "package.json"));
const packagePath = installedRequire.resolve("@heroiclands/package-build/package.json");
const enginePath = path.join(path.dirname(packagePath), "engine/index.mjs");
const { sitePreview } = await import(pathToFileURL(enginePath).href);
const cssPath = path.join(root, "node_modules/@heroiclands/hugo-theme/static/css/style.css");
let css = fs.existsSync(cssPath) ? fs.readFileSync(cssPath) : null;
let preview;
let server;
let version = Date.now();
let requested = 0;
let pending = null;
let busy = false;
let lastError = "";
let body = "<p>Preparing preview…</p>";
let infobox = "";

function send(value) {
    process.stdout.write(`${JSON.stringify(value)}\n`);
}

function htmlPage() {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HeroicLands preview</title><link rel="stylesheet" href="/style.css">
<style>body{max-width:80rem;margin:2rem auto;padding:0 1rem}
.single:not(.single-with-sidebar){max-width:60rem}
[hidden]{display:none!important}
article a{cursor:default}#preview-error{color:#c44;white-space:pre-wrap}
pre{overflow-x:auto}figure{max-width:100%}</style></head>
<body><p id="preview-error" role="status"></p><article class="single">
<aside class="info-rail" id="preview-infobox" hidden></aside>
<div class="single-content"><main class="single-body" id="preview-body"></main></div></article>
<script>
let seen = -1;
async function update() {
  try {
    const response = await fetch('/state', {cache:'no-store'});
    const state = await response.json();
    document.getElementById('preview-error').textContent = state.error;
    if (state.version !== seen) {
      const ratio = document.documentElement.scrollHeight > innerHeight
        ? scrollY / (document.documentElement.scrollHeight - innerHeight) : 0;
      const article = document.querySelector('article');
      const rail = document.getElementById('preview-infobox');
      rail.innerHTML = state.infobox;
      rail.hidden = !state.infobox;
      article.classList.toggle('single-with-sidebar', !!state.infobox);
      document.getElementById('preview-body').innerHTML = state.body;
      for (const link of article.querySelectorAll('a')) link.removeAttribute('href');
      for (const heading of article.querySelectorAll('h1,h2,h3,h4,h5,h6')) heading.removeAttribute('id');
      scrollTo(0, ratio * Math.max(0, document.documentElement.scrollHeight - innerHeight));
      seen = state.version;
    }
  } catch (error) {
    document.getElementById('preview-error').textContent = String(error);
  }
}
document.querySelector('article').addEventListener('click', event => {
  if (event.target.closest('a')) event.preventDefault();
});
update(); setInterval(update, 700);
</script></body></html>`;
}

function pandoc(markdown) {
    return new Promise((resolve, reject) => {
        const child = spawn("pandoc", ["-f", "markdown+raw_html+fenced_divs+pipe_tables", "-t", "html5", "--no-highlight"], { stdio: ["pipe", "pipe", "pipe"] });
        let output = "";
        let error = "";
        child.stdout.setEncoding("utf8").on("data", chunk => { output += chunk; });
        child.stderr.setEncoding("utf8").on("data", chunk => { error += chunk; });
        child.on("error", reject);
        child.on("close", code => code === 0 ? resolve(output) : reject(new Error(error || `pandoc exited ${code}`)));
        child.stdin.end(markdown);
    });
}

async function run() {
    if (busy || !pending || !preview) return;
    busy = true;
    const job = pending;
    pending = null;
    try {
        if (job.refresh) {
            await preview.refresh();
            css = fs.readFileSync(cssPath);
        }
        const result = await preview.render(file, job.text);
        if (job.generation !== requested) return;
        if (!result.ok) {
            lastError = result.findings.map(f => `${f.file}${f.line ? `:${f.line}` : ""}: ${f.message}`).join("\n");
            send({ type: "error", generation: job.generation, message: lastError });
            return;
        }
        const converted = await pandoc(result.markdown);
        if (job.generation !== requested) return;
        body = converted;
        infobox = job.infobox === false ? "" : renderInfoboxes(result.frontmatter.infoboxes);
        lastError = "";
        version++;
        send({ type: "rendered", generation: job.generation });
    } catch (error) {
        if (job.generation === requested) {
            lastError = String(error.message ?? error);
            send({ type: "error", generation: job.generation, message: lastError });
        }
    } finally {
        busy = false;
        if (pending) void run();
    }
}

async function start() {
    if (!css) throw new Error(`Site CSS is missing: ${cssPath}`);
    preview = await sitePreview.prepareSitePreview();
    server = http.createServer((request, response) => {
        const pathname = new URL(request.url, "http://localhost").pathname;
        if (pathname === "/style.css") {
            response.writeHead(200, { "Content-Type": "text/css; charset=utf-8" });
            response.end(css);
        } else if (pathname === "/state") {
            response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
            response.end(JSON.stringify({ version, body, infobox, error: lastError }));
        } else if (pathname === "/") {
            response.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
            response.end(htmlPage());
        } else {
            response.writeHead(404); response.end();
        }
    });
    await new Promise((resolve, reject) => server.once("error", reject).listen(port, "127.0.0.1", resolve));
    send({ type: "ready", url: `http://127.0.0.1:${server.address().port}/` });
    void run();
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", line => {
    try {
        const message = JSON.parse(line);
        if (message.type === "render") {
            requested = message.generation;
            pending = message;
            void run();
        } else if (message.type === "invalidate") {
            requested = message.generation;
            pending = null;
        } else if (message.type === "stop") {
            input.close();
        }
    } catch (error) {
        send({ type: "error", message: String(error.message ?? error) });
    }
});
input.on("close", async () => {
    if (server) server.close();
    if (preview) await preview.close();
    process.exit(0);
});
start().catch(error => {
    process.stdout.write(`${JSON.stringify({ type: "error", message: String(error.message ?? error) })}\n`,
        () => process.exit(1));
});
