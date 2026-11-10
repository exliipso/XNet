// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 exliipso
// Originally developed by exliipso

// Builds the README charts as light and dark SVGs from data.json.
//
//     node assets/charts/make.js
//
// XNet's rows are blue (native edition) and teal (Lua edition); every other
// library is neutral gray and named on its row, so no legend is needed.
// Multipliers after a value compare it with XNet's native edition.

const fs = require("fs");
const path = require("path");

const OUT = path.join(__dirname, "..");
const data = JSON.parse(fs.readFileSync(path.join(__dirname, "data.json"), "utf8"));

const THEMES = {
  light: {
    surface: "#fcfcfb", border: "rgba(11,11,11,0.10)", text: "#0b0b0b", text2: "#52514e", muted: "#898781",
    axis: "#c3c2b7", xnet: "#2a78d6", xnetlua: "#0f9a9a", other: "#a9a8a0", good: "#2a78d6", bad: "#e34948",
  },
  dark: {
    surface: "#1a1a19", border: "rgba(255,255,255,0.10)", text: "#f0efec", text2: "#c3c2b7", muted: "#898781",
    axis: "#383835", xnet: "#3987e5", xnetlua: "#20aaa6", other: "#62615c", good: "#3987e5", bad: "#e66767",
  },
};

const NAMES = {
  xnet: "XNet",
  xnetlua: "XNet (Lua edition)",
  xnetboth: "XNet (both editions)",
  raw: "Hand-written net",
  sfs: "sfs",
  netstream: "netstream (pON)",
  streamnet: "StreamNet",
  vnet: "vNet",
  von: "vON",
  freenet: "FreeNet",
  bnet: "bNet",
  writetable: "net.WriteTable",
  nct: "net_compressed_table",
};

const FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif";
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const isXNet = (key) => key === "xnet" || key === "xnetlua" || key === "xnetboth";
const colorOf = (t, key) => (key === "xnetlua" ? t.xnetlua : isXNet(key) ? t.xnet : t.other);

// A bar from the baseline with only its far end rounded (4px).
function bar(x, y, w, h, fill) {
  if (w <= 0) return "";
  const r = Math.min(4, w / 2, h / 2);
  return `<path d="M${x},${y} H${x + w - r} Q${x + w},${y} ${x + w},${y + r} V${y + h - r} Q${x + w},${y + h} ${x + w - r},${y + h} H${x} Z" fill="${fill}"/>`;
}

function text(x, y, s, { size = 13, fill, weight = 400, anchor = "start" } = {}) {
  return `<text x="${x}" y="${y}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}">${esc(s)}</text>`;
}

// Width estimate for laying out a label and its multiplier side by side.
const textWidth = (s, size) => String(s).length * size * 0.56;

function frame(t, w, h, body, title) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" role="img" aria-label="${esc(title)}">
<rect x="0.5" y="0.5" width="${w - 1}" height="${h - 1}" rx="12" fill="${t.surface}" stroke="${t.border}"/>
${body}
</svg>`;
}

function header(t, title, subtitle, padX) {
  let body = text(padX, 34, title, { size: 18, weight: 650, fill: t.text });
  body += text(padX, 56, subtitle, { size: 12.5, fill: t.text2 });
  return body;
}

// Horizontal bars, one row per library, each panel on its own scale.
// rows: [{key, value, label, note}]; a null value draws no bar, only the note.
function panels(t, { title, subtitle, footer, panelList, width = 860, compare = true }) {
  const padX = 28, labelW = 170, valueW = 150;
  const rowH = 24, panelGap = 22;
  const plotX = padX + labelW;
  const plotW = width - plotX - padX - valueW;

  let body = header(t, title, subtitle, padX);
  let y = 84;

  for (const p of panelList) {
    body += text(padX, y + 14, p.title, { size: 13.5, weight: 650, fill: t.text });
    if (p.subtitle) body += text(padX + textWidth(p.title, 13.5) + 10, y + 14, p.subtitle, { size: 12, fill: t.muted });
    y += 26;

    const values = p.rows.filter((r) => r.value != null).map((r) => r.value);
    const max = Math.max(...values);
    const base = p.rows.find((r) => r.key === "xnet" || r.key === "xnetboth");
    const top = y;

    for (const r of p.rows) {
      const strong = isXNet(r.key);
      body += text(padX, y + 16, NAMES[r.key], { size: 12.5, weight: strong ? 650 : 400, fill: strong ? t.text : t.text2 });

      if (r.value != null) {
        const w = Math.max(3, (r.value / max) * plotW);
        body += bar(plotX, y + 4, w, rowH - 8, colorOf(t, r.key));
        const lx = plotX + w + 8;
        body += text(lx, y + 16, r.label, { size: 12.5, weight: strong ? 650 : 400, fill: t.text });

        const ratio = compare && base && !isXNet(r.key) && base.value ? r.value / base.value : null;
        const extra = [ratio != null ? `${ratio >= 10 ? ratio.toFixed(0) : ratio.toFixed(1)}×` : null, r.tag].filter(Boolean).join(" · ");
        if (extra) body += text(lx + textWidth(r.label, 12.5) + 8, y + 16, extra, { size: 12, fill: t.muted });
      } else {
        body += text(plotX + 8, y + 16, r.note, { size: 12.5, fill: t.muted });
      }
      y += rowH;
    }

    body += `<line x1="${plotX}" y1="${top + 2}" x2="${plotX}" y2="${y - 2}" stroke="${t.axis}" stroke-width="1"/>`;
    y += panelGap;
  }

  if (footer) body += text(padX, y + 4, footer, { size: 11.5, fill: t.muted });
  return frame(t, width, y + 22, body, title);
}

// Diverging bars on a log scale around 1×: right = XNet better, left = worse.
function diverging(t, { title, subtitle, footer, groups, width = 860 }) {
  const padX = 28, labelW = 150, rowH = 24;
  let body = header(t, title, subtitle, padX);
  let y = 88;

  const plotX = padX + labelW;
  const plotW = width - plotX - padX;
  const span = Math.log2(6);
  const mid = plotX + plotW * 0.3;
  const left = mid - plotX, right = plotX + plotW - mid - 90;
  const scale = (ratio) => {
    const v = Math.max(-span, Math.min(span, Math.log2(ratio)));
    return v >= 0 ? (v / span) * right : (v / span) * left;
  };

  body += text(mid - 8, y, "← net.WriteTable better", { size: 11.5, fill: t.muted, anchor: "end" });
  body += text(mid + 8, y, "XNet better →", { size: 11.5, fill: t.muted });
  y += 12;
  const top = y;

  for (const g of groups) {
    body += text(padX, y + 16, g.title, { size: 13.5, weight: 650, fill: t.text });
    y += 26;
    for (const r of g.rows) {
      body += text(padX + 10, y + 16, r.label, { size: 12.5, fill: t.text2 });
      const w = scale(r.ratio);
      if (r.ratio >= 1) {
        body += bar(mid, y + 4, Math.max(3, w), rowH - 8, t.good);
        body += text(mid + Math.max(3, w) + 8, y + 16, r.text, { size: 12.5, weight: 650, fill: t.text });
      } else {
        const bw = Math.max(3, -w), x = mid - bw, h = rowH - 8, yy = y + 4, rr = Math.min(4, bw / 2, h / 2);
        body += `<path d="M${mid},${yy} H${x + rr} Q${x},${yy} ${x},${yy + rr} V${yy + h - rr} Q${x},${yy + h} ${x + rr},${yy + h} H${mid} Z" fill="${t.bad}"/>`;
        body += text(x - 8, y + 16, r.text, { size: 12.5, weight: 650, fill: t.text, anchor: "end" });
      }
      y += rowH;
    }
    y += 10;
  }

  body += `<line x1="${mid}" y1="${top}" x2="${mid}" y2="${y - 10}" stroke="${t.axis}" stroke-width="1.5"/>`;
  if (footer) body += text(padX, y + 8, footer, { size: 11.5, fill: t.muted });
  return frame(t, width, y + 26, body, title);
}

function hero(t, { stats, width = 860 }) {
  let body = text(36, 66, "XNet", { size: 46, weight: 750, fill: t.text });
  body += text(38, 94, "Fast, safe networking for Garry's Mod. Send any Lua value, any size.", { size: 15, fill: t.text2 });
  body += `<rect x="36" y="114" width="44" height="4" rx="2" fill="${t.xnet}"/>`;
  const colW = (width - 72) / stats.length;
  stats.forEach((s, i) => {
    const x = 36 + i * colW;
    body += text(x, 172, s.big, { size: 34, weight: 750, fill: t.text });
    body += text(x, 196, s.small, { size: 12.5, fill: t.text2 });
    if (s.small2) body += text(x, 214, s.small2, { size: 12.5, fill: t.text2 });
  });
  return frame(t, width, 240, body, "XNet");
}

let written = 0;

for (const [mode, t] of Object.entries(THEMES)) {
  const write = (name, svg) => {
    fs.writeFileSync(path.join(OUT, `${name}-${mode}.svg`), svg);
    written++;
  };
  write("hero", hero(t, data.hero));
  write("small", panels(t, data.small));
  write("serializer", panels(t, data.serializer));
  write("size", panels(t, data.size));
  write("transfers", panels(t, data.transfers));
  write("writetable", diverging(t, data.writetable));
}

console.log(`wrote ${written} charts to ${OUT}`);
