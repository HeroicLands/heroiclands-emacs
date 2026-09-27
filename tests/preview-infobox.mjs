/* SPDX-License-Identifier: GPL-3.0-or-later */

import assert from "node:assert/strict";
import { test } from "node:test";
import { renderInfoboxes } from "../heroiclands-preview-infobox.mjs";

test("generated infobox fields keep their order and site layout classes", () => {
    const boxes = [
        { id: "empty", kind: "note", title: "Empty", sections: [] },
        { id: "profile", kind: "note", title: "Profile", sections: [
            { id: "facts", layout: "rows", label: "Facts", rows: [
                { label: "Population", kind: "number", value: 1500 },
                { label: "Patron", kind: "link", value: { text: "A & B", url: "/person/" } },
            ] },
            { id: "scores", layout: "grid", label: "Scores", cells: [
                { label: "Guard", value: 0 },
            ] },
            { layout: "runin", label: "Trades", groups: [
                { label: "Guilds", entries: [{ text: "Weavers", url: "/weavers/" }] },
            ] },
            { layout: "list", label: "Places", entries: [
                { text: "East", url: "/east/" }, { text: "West" },
            ] },
        ] },
        { id: "sohl", kind: "system", title: "System", statement: "No actor data", sections: [] },
    ];
    const html = renderInfoboxes(boxes);
    assert.doesNotMatch(html, /Empty/);
    assert.match(html, /class="info-sidebar info-box info-box-profile" open/);
    assert.match(html, /class="info-profile-grid"/);
    assert.match(html, /class="info-attrs-grid"/);
    assert.match(html, /class="info-skill-line"/);
    assert.match(html, /class="info-mystical-list"/);
    assert.match(html, /1,500/);
    assert.match(html, /A &amp; B/);
    assert.match(html, /<span class="attr-value">0<\/span>/);
    assert.match(html, /No actor data/);
    const ordered = ["Profile", "Facts", "Population", "Patron", "Scores", "Guard",
        "Trades", "Weavers", "Places", "East", "West", "System"];
    let previous = -1;
    for (const text of ordered) {
        const index = html.indexOf(text);
        assert.ok(index > previous, `${text} stays in generated order`);
        previous = index;
    }
});

test("infobox HTML escapes generated strings", () => {
    const html = renderInfoboxes([{ kind: "note", title: "<script>", sections: [
        { layout: "rows", rows: [{ label: "X", kind: "text", value: "<img>" }] },
    ] }]);
    assert.match(html, /&lt;script&gt;/);
    assert.match(html, /&lt;img&gt;/);
    assert.doesNotMatch(html, /<script>/);
});
