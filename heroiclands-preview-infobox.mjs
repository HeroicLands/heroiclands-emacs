/* SPDX-License-Identifier: GPL-3.0-or-later */

/** Draw generated infobox metadata with the site's generic infobox classes. */

const escape = value => String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");

const itemsFor = section => ({
    rows: section.rows,
    grid: section.cells,
    runin: section.groups,
    list: section.entries,
})[section.layout] ?? [];

function entryHtml(entry, className) {
    const text = escape(entry?.text);
    const cls = escape(className);
    return entry?.url
        ? `<a class="${cls}" href="${escape(entry.url)}">${text}</a>`
        : `<span class="${cls}">${text}</span>`;
}

function valueHtml(row) {
    switch (row.kind) {
        case "link": return entryHtml(row.value, "info-link");
        case "links": return (row.value ?? []).map(value => entryHtml(value, "info-link")).join(", ");
        case "list": return (row.value ?? []).map(escape).join(", ");
        case "number": {
            const value = String(row.value ?? "");
            return /^-?\d+$/.test(value) ? BigInt(value).toLocaleString("en-US") : escape(value);
        }
        default: return escape(row.value);
    }
}

function sectionHtml(section) {
    const items = itemsFor(section);
    if (!items.length) return "";
    const cls = `info-section${section.id ? ` info-section-${escape(section.id)}` : ""}`;
    let content = "";
    if (section.layout === "rows") {
        content = `<dl class="info-profile-grid">${items.map(row =>
            `<dt>${escape(row.label)}</dt><dd>${valueHtml(row)}</dd>`).join("")}</dl>`;
    } else if (section.layout === "grid") {
        content = `<div class="info-attrs-grid">${items.map(cell =>
            `<div class="info-attr"><span class="attr-label">${escape(cell.label)}</span>` +
            `<span class="attr-value">${escape(cell.value)}</span></div>`).join("")}</div>`;
    } else if (section.layout === "runin") {
        content = items.map(group =>
            `<p class="info-skill-line">${group.label ?
                `<span class="skill-cat">${escape(group.label)}:</span>` : ""}` +
            `<span class="skill-entries">${(group.entries ?? [])
                .map(entry => entryHtml(entry, "skill-entry")).join(", ")}</span></p>`).join("");
    } else if (section.layout === "list") {
        content = `<ul class="info-mystical-list">${items.map(entry =>
            `<li class="info-mystical-item">${entryHtml(entry, "mystical-name")}</li>`
        ).join("")}</ul>`;
    }
    return `<section class="${cls}">${section.label ?
        `<h3 class="info-section-title">${escape(section.label)}</h3>` : ""}${content}</section>`;
}

export function renderInfoboxes(boxes) {
    return (boxes ?? []).map(box => {
        const sections = (box.sections ?? []).map(sectionHtml).filter(Boolean);
        if (box.kind !== "system" && !sections.length) return "";
        const cls = `info-sidebar info-box${box.id ? ` info-box-${escape(box.id)}` : ""}`;
        const inner = box.statement
            ? `<p class="info-statement">${escape(box.statement)}</p>`
            : sections.join("");
        return `<details class="${cls}" open><summary class="info-sidebar-title">` +
            `<h2>${escape(box.title)}</h2></summary>${inner}</details>`;
    }).filter(Boolean).join("\n");
}
