/* SPDX-License-Identifier: GPL-3.0-or-later */

import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import readline from "node:readline";

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
let renderPreview;
let readPreviewCurrentDate;
let css;
try {
    const previewPath = installedRequire.resolve("@heroiclands/package-build/preview");
    const preview = await import(pathToFileURL(previewPath).href);
    renderPreview = preview.renderPreview;
    readPreviewCurrentDate = preview.readPreviewCurrentDate;
    if (typeof readPreviewCurrentDate !== "function") {
        throw new Error("The installed preview API does not provide readPreviewCurrentDate");
    }
    css = preview.previewStyles();
} catch (error) {
    process.stdout.write(`${JSON.stringify({ type: "error", message:
        `Source preview requires package-build with the preview export. Update the pinned server installation: ${error.message}` })}\n`);
    process.exit(1);
}
let server;
let version = Date.now();
let requested = 0;
let pending = null;
let busy = false;
let lastError = "";
let dark = false;
let body = "<p>Preparing preview…</p>";

function send(value) {
    process.stdout.write(`${JSON.stringify(value)}\n`);
}

function htmlPage() {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>HeroicLands preview</title><link rel="stylesheet" href="/style.css">
<style>body{margin:0}
#preview-body{max-width:80rem;margin:auto}
#preview-error{margin:1rem}
[hidden]{display:none!important}
article a{cursor:default}#preview-error{color:#c44;white-space:pre-wrap}
pre{overflow-x:auto}figure{max-width:100%}</style></head>
<body><p id="preview-error" role="status"></p><article id="preview-body"></article>
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
      article.innerHTML = state.body;
      document.body.style.backgroundColor = state.dark ? '#0d1117' : '#ffffff';
      document.body.style.color = state.dark ? '#e6edf3' : '#24292f';
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

async function run() {
    if (busy || !pending || !server) return;
    busy = true;
    const job = pending;
    pending = null;
    try {
        const currentDate = await readPreviewCurrentDate(root);
        if (job.generation !== requested) return;
        const result = await renderPreview(job.text, {
            dark: job.dark === true, infobox: job.infobox !== false, file, currentDate,
        });
        if (job.generation !== requested) return;
        if (!result.ok) {
            lastError = result.findings.map(f => `${f.file}${f.line ? `:${f.line}` : ""}: ${f.message}`).join("\n");
            send({ type: "error", generation: job.generation, message: lastError });
            return;
        }
        body = result.html;
        dark = job.dark === true;
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
    server = http.createServer((request, response) => {
        const pathname = new URL(request.url, "http://localhost").pathname;
        if (pathname === "/style.css") {
            response.writeHead(200, { "Content-Type": "text/css; charset=utf-8" });
            response.end(css);
        } else if (pathname === "/state") {
            response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
            response.end(JSON.stringify({ version, body, dark, error: lastError }));
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
    process.exit(0);
});
start().catch(error => {
    process.stdout.write(`${JSON.stringify({ type: "error", message: String(error.message ?? error) })}\n`,
        () => process.exit(1));
});
